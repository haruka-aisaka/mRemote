import MetalKit
import QuartzCore
import UIKit
import InputCore
import SessionCore

/// The Metal surface the remote desktop is drawn on.
///
/// docs/architecture.md section 6 is the specification: the protocol worker
/// copies a BGRA surface into `LatestDesktopFrameStore`, the store raises one
/// coalesced signal, and this view uploads only the damaged region before
/// presenting. Metal composites and scales; it never decodes.
///
/// An indirect pointer - a trackpad or a mouse - drives the *remote* pointer:
/// hover moves it, a click is a button, a two-finger scroll is a wheel.
/// What a finger does is the user's choice (`TouchPointerMode`): click and
/// drag where it touches, move the pointer as a trackpad, or only move the
/// *local* viewport - one finger pans, a double tap switches between fit and
/// 100%. Pinch zooms the viewport in every mode, and is the only gesture
/// that never reaches the host, so no gesture means two things at once.
///
/// Keyboard capture is here too, and it is the reason this project exists:
/// the view is a plain `UIView` responder that never conforms to `UIKeyInput`
/// or `UITextInput`, and it does not forward a press it handled to `super`.
/// That combination is what keeps iPadOS from consuming 英数/かな for its own
/// input-source switcher (`KEY-IME-02`), so they can reach Windows as
/// 無変換/変換 instead. `GCKeyboard` reports reach the same
/// `KeyboardEventArbiter`, which binds each usage to one source so a press
/// seen by both is still sent once (KEY-04).
///
/// The server's cursor is drawn here too, as a layer that follows the local
/// pointer, with the system pointer hidden while a shape is shown: iPadOS
/// cannot be given an arbitrary bitmap as its pointer.
@MainActor
final class RemoteDesktopView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate,
    UIPointerInteractionDelegate, RemotePointerControl, DirectPointerControl {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct RasterizerData {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    // rect is (left, top, right, bottom) in normalised device coordinates, so
    // a desktop that is zoomed past the edges of the screen is clipped by the
    // rasteriser instead of needing a viewport the render target cannot hold.
    // source is the part of the texture shown, in texture coordinates: all
    // of it, or this screen's half of a desktop spread over two monitors.
    vertex RasterizerData desktopVertex(
        uint vertexID [[vertex_id]],
        constant float4 &rect [[buffer(0)]],
        constant float4 &source [[buffer(1)]]) {
        const float2 corners[] = {
            float2(0.0, 0.0), float2(1.0, 0.0),
            float2(0.0, 1.0), float2(1.0, 1.0)
        };
        float2 corner = corners[vertexID];
        RasterizerData output;
        output.position = float4(
            mix(rect.x, rect.z, corner.x),
            mix(rect.y, rect.w, corner.y),
            0.0,
            1.0);
        output.textureCoordinate = float2(
            mix(source.x, source.z, corner.x),
            mix(source.y, source.w, corner.y));
        return output;
    }

    fragment float4 desktopFragment(
        RasterizerData input [[stage_in]],
        texture2d<float> desktop [[texture(0)]]) {
        // Nearest when magnifying keeps remote text crisp rather than smeared;
        // linear when minifying stops a 1080p desktop shrunk to fit from
        // shimmering.
        constexpr sampler desktopSampler(mag_filter::nearest, min_filter::linear);
        return desktop.sample(desktopSampler, input.textureCoordinate);
    }
    """

    /// Raised when the desktop's own size changes, so the workspace can ask
    /// the server for a different one or re-fit what it already has.
    var onDesktopSizeChange: ((Int, Int) -> Void)?
    /// The drawable size in pixels, which is what a dynamic resolution
    /// request has to be expressed in: asking the server for the size in
    /// points would hand back a desktop at half the device's resolution.
    var onRenderSizeChange: ((Int, Int) -> Void)?
    var onTransformChange: ((ViewportTransform) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    /// Called whenever a key observation changed the counters. The snapshot
    /// carries no characters; see `InputDiagnostics`.
    var onInputDiagnostics: ((InputDiagnostics) -> Void)?

    /// Where pointer input goes. Set by the surface once the session exists;
    /// nil means the events are tracked locally but sent nowhere.
    var inputSink: (any DesktopInputSink)? {
        didSet {
            guard inputSink !== oldValue else { return }
            // Whatever was held belonged to the previous session; releasing it
            // through the new sink would press nothing and unpress something
            // that is not there, so this only clears local state.
            releaseHeldButtons()
            releaseHeldKeys()
        }
    }

    private let frameStore: LatestDesktopFrameStore
    private let cursorStore: RemoteCursorStore?
    private let cursorLayer = CALayer()
    private var pointerInteraction: UIPointerInteraction?
    private var hoverLocation: CGPoint?
    private var remoteCursor: RemoteCursor = .systemDefault
    private var remoteCursorImage: CGImage?
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var desktopTexture: MTLTexture?
    private var lastSubmittedCommandBuffer: MTLCommandBuffer?
    private var desktopSize = (width: 1, height: 1)
    private var scaleMode: InitialScale
    private var zoom: Double = 1
    private var pan = ViewportPoint.zero
    private var panOrigin = ViewportPoint.zero
    private var zoomOrigin: Double = 1
    private var pinchStart = CGPoint.zero
    private var hasPresentedAFrame = false
    private var pointerRouter: PointerInputRouter
    private var keyboard = KeyboardEventArbiter()
    private var keyRepeatTimer: Timer?
    /// Buttons the platform reports as held right now. Kept so a touch phase
    /// that carries no button mask does not read as "everything released".
    private var indirectButtons: Set<PointerButton> = []
    /// The Mac's right and middle buttons, which arrive from AppKit rather
    /// than with the touches (`MacKeyboardCapture`).
    private var macButtons: Set<PointerButton> = []
    /// Buttons held on the laptop deck's trackpad, which has its own: a
    /// tap-to-click there must not let go of a drag held with its button.
    private var laptopButtons: Set<PointerButton> = []
    /// Where the laptop deck's trackpad put the remote pointer. Kept as a
    /// desktop pixel rather than a local point so a zoom or a resize redraws
    /// the cursor where the pointer is, not where it was on screen.
    private var relativePointerPixel: PixelPoint?
    private var relativeMotion = RelativePointerMotion()
    /// What a finger on the desktop does: click where it is, move the
    /// pointer as a trackpad would, or only pan the view. Pinch zooms in
    /// all three.
    private var touchMode = TouchPointerMode.viewport
    private lazy var directTrackpad = TrackpadGestureTracker { [weak self] in self }
    private lazy var directTouch = DirectTouchGestureTracker { [weak self] in self }
    /// Buttons held by a finger in direct mode, kept apart from the deck's
    /// and the trackpad's for the same reason those are kept apart.
    private var touchButtons: Set<PointerButton> = []
    private var viewportPan: UIPanGestureRecognizer?
    /// Fingers down as Windows touches, by the contact number each was given.
    private var touchContacts: [ObjectIdentifier: (id: UInt32, pixel: PixelPoint)] = [:]
    /// Direct mode's fingers down now, and whether this gesture goes to a
    /// host that takes touches as touches - decided when the first finger
    /// lands, so a gesture never changes hands halfway.
    private var directFingers: Set<ObjectIdentifier> = []
    private var directGoesAsTouch = false
    /// The first finger of a touch gesture, not sent yet: a second finger
    /// landing meanwhile makes it a mouse gesture without the host ever
    /// seeing a touch. A touch taken back later is a cancel, and Windows
    /// (Edge, at least) still treats a quick down and cancel as a tap.
    private var heldTouch: (touch: UITouch, location: CGPoint)?
    private var heldTouchTimer: Timer?
    static let touchHoldBack: TimeInterval = 0.1
    /// The pencil while it is down as a pen.
    private var penContact: (touch: ObjectIdentifier, pixel: PixelPoint)?
    var sendsPencilAsPen = true
    /// The size, in points, to ask the server for instead of this view's own:
    /// the whole screen while the laptop deck takes part of it and the user
    /// would rather keep the resolution and draw it smaller.
    private var renderSizeOverride: CGSize?
    /// This screen's part of a desktop that spans a monitor too: the top
    /// left of the framebuffer, this wide and tall. Nil for all of it.
    private var primaryRegion: (width: Int, height: Int)?

    /// What this view shows and maps touches into: the framebuffer, or its
    /// primary part. The pointer still moves over the whole desktop.
    private var transformDesktopSize: (width: Int, height: Int) {
        guard let primaryRegion else { return desktopSize }
        return (min(primaryRegion.width, desktopSize.width), min(primaryRegion.height, desktopSize.height))
    }

    func setPrimaryRegion(_ region: (width: Int, height: Int)?) {
        guard region?.width != primaryRegion?.width || region?.height != primaryRegion?.height else { return }
        primaryRegion = region
        updateTransform()
        setNeedsDisplay()
    }
    /// A second screen showing this desktop: it reads the texture this view
    /// uploads into and is told where the pointer is.
    var mirror: DesktopMirror? {
        didSet {
            guard mirror !== oldValue else { return }
            mirror?.publish(texture: desktopTexture)
            positionCursorLayer()
        }
    }
    /// How far up the software keyboard reaches into this view.
    private var keyboardOverlap: CGFloat = 0
    /// Whether the desktop is lifted above the software keyboard to keep the
    /// pointer in sight, as the Windows App on iPhone does.
    private var followsPointerAboveKeyboard = true
    private var viewportDoubleTap: UITapGestureRecognizer?
    /// False until the surface is configured, so nothing is delivered before
    /// the workspace has said whether the session can carry it.
    private var isInputEnabled = false
    /// True while the software keyboard's proxy is first responder.
    private var isKeyboardCaptureSuppressed = false

    private(set) var viewportTransform: ViewportTransform

    init(
        frameStore: LatestDesktopFrameStore,
        cursorStore: RemoteCursorStore?,
        scaleMode: InitialScale,
        scrollDirection: ScrollDirection
    ) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else {
            // Every device this app supports has Metal; a failure here is a
            // broken build rather than an unsupported device, and continuing
            // would only produce a black screen with no explanation.
            fatalError("Metal is required to present a remote desktop")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "desktopVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "desktopFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            fatalError("Could not create the remote desktop render pipeline")
        }

        self.frameStore = frameStore
        self.cursorStore = cursorStore
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.scaleMode = scaleMode
        let transform = ViewportTransform(
            desktopWidth: 1,
            desktopHeight: 1,
            viewport: .zero,
            scaleMode: scaleMode
        )
        viewportTransform = transform
        pointerRouter = PointerInputRouter(
            transform: transform,
            scrollDirection: scrollDirection
        )
        super.init(frame: .zero, device: device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        framebufferOnly = true
        // Driven by the frame store rather than by a display link: a desktop
        // that is not changing should not wake the GPU sixty times a second.
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        delegate = self
        isOpaque = true
        isMultipleTouchEnabled = true
        isUserInteractionEnabled = true
        accessibilityLabel = String(localized: "リモートデスクトップ")
        accessibilityIdentifier = "remote-desktop-surface"

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        // Direct touches only: a trackpad drag is the remote pointer's, not
        // the viewport's.
        let drag = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        drag.delegate = self
        addGestureRecognizer(drag)
        viewportPan = drag

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(doubleTap)
        viewportDoubleTap = doubleTap

        // The mirror image: no touch types at all, so this recogniser only ever
        // sees indirect scroll events from a trackpad or a wheel.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        addGestureRecognizer(scroll)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)

        let pointer = UIPointerInteraction(delegate: self)
        addInteraction(pointer)
        pointerInteraction = pointer

        cursorLayer.isHidden = true
        cursorLayer.contentsGravity = .resize
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.zPosition = 1
        layer.addSublayer(cursorLayer)

        attachToFrameStore()
        attachToCursorStore()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardFrameWillChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillHide(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The store outlives the view - it belongs to the session - so the signal
    /// must not keep this view alive, and a frame that arrives after the view
    /// is gone has to be a no-op rather than a resurrection.
    private func attachToFrameStore() {
        frameStore.setSignal { [weak self] in
            Task { @MainActor in self?.drainFrameStore() }
        }
    }

    func detachFromFrameStore() {
        frameStore.setSignal(nil)
        cursorStore?.setSignal(nil)
    }

    private func attachToCursorStore() {
        cursorStore?.setSignal { [weak self] in
            Task { @MainActor in self?.applyRemoteCursor() }
        }
        applyRemoteCursor()
    }

    deinit {
        // `deinit` is nonisolated, so the store's signal is cleared here
        // through the store itself rather than by touching the view. The
        // repeat timer needs nothing: it never repeats, it holds only a weak
        // reference back here, and it is re-armed rather than reused.
        frameStore.setSignal(nil)
        cursorStore?.setSignal(nil)
    }

    // MARK: - Presentation

    private func drainFrameStore() {
        guard let frame = frameStore.consume() else { return }
        apply(frame)
    }

    private func apply(_ frame: DesktopFrame) {
        guard let validated = try? DesktopFrameValidator.validate(frame) else {
            onDiagnostic?("dropped a frame that failed validation")
            return
        }
        // One shared texture, so a CPU write has to be ordered behind the GPU
        // read that is already in flight. Phase 4's multi-session work is
        // where this becomes multi-buffered; making the cost visible now is
        // better than hiding it behind a silent tear.
        waitForSubmittedTextureRead()

        let needsNewTexture = desktopTexture?.width != frame.width
            || desktopTexture?.height != frame.height
        if needsNewTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: frame.width,
                height: frame.height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            guard let texture = device?.makeTexture(descriptor: descriptor) else {
                onDiagnostic?("could not allocate a \(frame.width)x\(frame.height) texture")
                return
            }
            desktopTexture = texture
            desktopSize = (frame.width, frame.height)
            updateTransform(desktopChanged: true)
            onDesktopSizeChange?(frame.width, frame.height)
        }

        // A fresh texture holds undefined pixels, so the first upload after an
        // allocation covers the whole surface however small the damage claims
        // to be.
        let rectangles = validated.rectanglesForUpload(requiresFullSeed: needsNewTexture)
        frame.pixels.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress, let texture = desktopTexture else { return }
            for rectangle in rectangles {
                let offset = rectangle.y * frame.bytesPerRow + rectangle.x * 4
                texture.replace(
                    region: MTLRegionMake2D(
                        rectangle.x,
                        rectangle.y,
                        rectangle.width,
                        rectangle.height
                    ),
                    mipmapLevel: 0,
                    withBytes: base.advanced(by: offset),
                    bytesPerRow: frame.bytesPerRow
                )
            }
        }
        hasPresentedAFrame = true
        setNeedsDisplay()
        mirror?.publish(texture: desktopTexture)
    }

    private func waitForSubmittedTextureRead() {
        mirror?.waitForReads()
        guard let commandBuffer = lastSubmittedCommandBuffer else { return }
        switch commandBuffer.status {
        case .completed, .error:
            break
        default:
            commandBuffer.waitUntilCompleted()
        }
        if commandBuffer.status == .error {
            onDiagnostic?("a Metal command failed: \(commandBuffer.error?.localizedDescription ?? "unknown")")
        }
        lastSubmittedCommandBuffer = nil
    }

    // MARK: - Viewport

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTransform()
        reportRenderSize()
        // Drawn again at the new size now: when the desktop keeps its size -
        // a fixed resolution, a server without the display channel - no new
        // frame comes to do it, and the old picture is stretched to fit.
        setNeedsDisplay()
    }

    func setRenderSizeOverride(_ size: CGSize?) {
        guard size != renderSizeOverride else { return }
        renderSizeOverride = size
        reportRenderSize()
    }

    private func reportRenderSize() {
        let scale = window?.screen.scale ?? contentScaleFactor
        let size = renderSizeOverride ?? bounds.size
        onRenderSizeChange?(
            Int((size.width * scale).rounded()),
            Int((size.height * scale).rounded())
        )
    }

    func setScaleMode(_ mode: InitialScale) {
        guard mode != scaleMode else { return }
        scaleMode = mode
        // Switching modes rescales everything, so a zoom measured against the
        // old scale means nothing and a pan measured against the old content
        // rectangle even less.
        zoom = 1
        pan = .zero
        updateTransform()
        setNeedsDisplay()
    }

    private func updateTransform(desktopChanged: Bool = false) {
        if desktopChanged {
            zoom = 1
            pan = .zero
        }
        viewportTransform = ViewportTransform(
            desktopWidth: transformDesktopSize.width,
            desktopHeight: transformDesktopSize.height,
            viewport: ViewportSize(width: bounds.width, height: bounds.height),
            scaleMode: scaleMode,
            zoom: zoom,
            pan: pan,
            occludedBottom: followsPointerAboveKeyboard ? Double(keyboardOverlap) : 0
        )
        // Clamping happens inside the transform, so read the accepted values
        // back rather than keeping a copy that disagrees with what is drawn.
        pan = viewportTransform.pan
        zoom = viewportTransform.zoom
        pointerRouter.transform = viewportTransform
        if desktopChanged {
            // The remembered pixel was measured against a surface that no
            // longer exists, so the next move must be sent even if it lands on
            // the same number.
            pointerRouter.forgetPosition()
            relativePointerPixel = nil
            relativeMotion.reset()
        }
        onTransformChange?(viewportTransform)
        positionCursorLayer()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            zoomOrigin = zoom
            panOrigin = pan
            pinchStart = location
        case .changed, .ended:
            zoom = ViewportTransform.clampZoom(zoomOrigin * Double(recognizer.scale))
            // With one finger given to the host, moving the pinch is the way
            // left to move the view.
            if viewportPan?.isEnabled == false, recognizer.numberOfTouches >= 2 {
                pan = ViewportPoint(
                    x: panOrigin.x + Double(location.x - pinchStart.x),
                    y: panOrigin.y + Double(location.y - pinchStart.y)
                )
            }
            updateTransform()
            setNeedsDisplay()
        default:
            break
        }
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            panOrigin = pan
        case .changed, .ended:
            let translation = recognizer.translation(in: self)
            pan = ViewportPoint(
                x: panOrigin.x + Double(translation.x),
                y: panOrigin.y + Double(translation.y)
            )
            updateTransform()
            setNeedsDisplay()
        default:
            break
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        setScaleMode(scaleMode == .fit ? .oneToOne : .fit)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        // Pinch and drag together are one gesture from the user's point of
        // view; recognising them one at a time makes zooming feel like it
        // fights the pan.
        true
    }

    // MARK: - Remote pointer

    func setScrollDirection(_ direction: ScrollDirection) {
        pointerRouter.setScrollDirection(direction)
    }

    /// Disabling releases whatever is held. docs/architecture.md section 10
    /// requires it on focus loss and scene deactivation: a click that begins
    /// here and ends somewhere the app never sees would otherwise leave the
    /// button down on Windows, turning the next move into a drag across the
    /// desktop.
    func setInputEnabled(_ enabled: Bool) {
        guard enabled != isInputEnabled else {
            if enabled { captureKeyboardIfPossible() }
            return
        }
        isInputEnabled = enabled
        accessibilityValue = enabled ? String(localized: "入力可") : String(localized: "入力不可")
        directTrackpad.setEnabled(enabled && touchMode == .trackpad)
        directTouch.setEnabled(enabled && touchMode == .direct)
        if enabled {
            if let held = HardwareKeyboardMonitor.shared.physicallyHeldUsages() {
                keyboard.reconcile(physicallyHeld: held)
            }
            apply(keyboard.setGate(open: true))
            captureKeyboardIfPossible()
        } else {
            releaseHeldButtons()
            stopKeyRepeat()
            send(keyboard.setGate(open: false))
            _ = resignFirstResponder()
        }
        publishDiagnostics()
    }

    func setInputTraceEnabled(_ enabled: Bool) {
        guard enabled != keyboard.diagnostics.isTraceEnabled else { return }
        keyboard.setTraceEnabled(enabled)
        publishDiagnostics()
    }

    private func publishDiagnostics() {
        onInputDiagnostics?(keyboard.diagnostics)
    }

    func releaseHeldButtons() {
        liftTouches()
        indirectButtons = []
        macButtons = []
        laptopButtons = []
        touchButtons = []
        deliver(pointerRouter.releaseAll())
    }

    func setKeyRepeat(_ settings: KeyRepeatSettings) {
        apply(keyboard.setRepeatSettings(settings))
    }

    private func deliver(_ events: [PointerInput]) {
        guard let inputSink, isInputEnabled else { return }
        for event in events {
            inputSink.send(event)
        }
    }

    private func viewportPoint(_ point: CGPoint) -> ViewportPoint {
        ViewportPoint(x: Double(point.x), y: Double(point.y))
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        // Apple Pencil above the screen (iPad Pro): a pen in range, not a
        // pointer move. Only a pencil reports a height.
        if sendsPencilAsPen, recognizer.zOffset > 0 {
            if recognizer.state == .began || recognizer.state == .changed {
                penHover(at: recognizer.location(in: self), recognizer: recognizer)
            }
            return
        }
        switch recognizer.state {
        case .began, .changed:
            hoverLocation = recognizer.location(in: self)
            relativePointerPixel = nil
            positionCursorLayer()
            deliver(pointerRouter.moved(to: viewportPoint(recognizer.location(in: self))))
        case .ended, .cancelled:
            hoverLocation = nil
            positionCursorLayer()
            // The pointer left the surface. Nothing is sent - the remote
            // pointer simply stays where it was - but a button held on the way
            // out has to be released.
            releaseHeldButtons()
        default:
            break
        }
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began, .changed:
            let delta = recognizer.translation(in: self)
            guard delta != .zero else { return }
            recognizer.setTranslation(.zero, in: self)
            deliver(pointerRouter.scrolled(
                horizontal: Double(delta.x),
                vertical: Double(delta.y)
            ))
        case .ended, .cancelled, .failed:
            recognizer.setTranslation(.zero, in: self)
        default:
            break
        }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        // Click or tap to take the keyboard back. SwiftUI can move the first
        // responder for reasons of its own - a menu, a sheet that has been
        // dismissed - and without this the user would have no way to recover
        // it short of leaving the session.
        captureKeyboardIfPossible()
        guard handleIndirectPointer(touches, event: event, ending: false) else {
            for touch in touches where touch.type == .pencil && sendsPencilAsPen {
                pen(touch, phase: .down)
            }
            for touch in touches where touch.type == .direct {
                switch touchMode {
                case .trackpad: directTrackpad.began(touch, in: self)
                case .direct: directBegan(touch, event: event)
                case .viewport: break
                }
            }
            super.touchesBegan(touches, with: event)
            return
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard handleIndirectPointer(touches, event: event, ending: false) else {
            let direct: [UITouch] = touches.filter { $0.type == .direct }
            for touch in touches where touch.type == .pencil && sendsPencilAsPen {
                pen(touch, phase: .move)
            }
            switch touchMode {
            case .trackpad: directTrackpad.moved(direct, in: self)
            case .direct where directGoesAsTouch:
                // Moving off means one finger, a drag: no waiting for a second.
                if let held = heldTouch, direct.contains(held.touch) {
                    let now = held.touch.location(in: self)
                    if hypot(now.x - held.location.x, now.y - held.location.y) >= DirectTouchGestureTracker.tapTravel {
                        sendHeldTouch()
                    }
                }
                direct.forEach { remoteTouch($0, phase: .move) }
            case .direct: directTouch.moved(direct, in: self)
            case .viewport: break
            }
            super.touchesMoved(touches, with: event)
            return
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard handleIndirectPointer(touches, event: event, ending: true) else {
            touchesFinished(touches, cancelled: false)
            super.touchesEnded(touches, with: event)
            return
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard handleIndirectPointer(touches, event: event, ending: true) else {
            // A pinch taking over cancels the touches, which ends whatever the
            // trackpad thought was happening without a click.
            touchesFinished(touches, cancelled: true)
            super.touchesCancelled(touches, with: event)
            return
        }
    }

    /// Returns true when the touch belonged to a trackpad or mouse and has
    /// been turned into remote pointer input; false leaves it to the viewport
    /// gestures.
    ///
    /// The button *set* is read from the event rather than inferred from the
    /// phase. UIKit reports what is held now, which is the only way a chord
    /// change or a release the app never saw can be handled correctly.
    private func handleIndirectPointer(
        _ touches: Set<UITouch>,
        event: UIEvent?,
        ending: Bool
    ) -> Bool {
        guard touches.contains(where: { $0.type == .indirectPointer }) else { return false }
        let location = touches.first { $0.type == .indirectPointer }?.location(in: self)
        if let location {
            // A drag carries the pointer with it; hover does not fire then.
            hoverLocation = location
            relativePointerPixel = nil
            positionCursorLayer()
        }
        // An ending touch releases everything rather than trusting the mask,
        // which may still name the button that is lifting. On a two-button
        // chord that releases one button, this releases both and the next
        // event presses the survivor again - a visible flicker, but the
        // alternative is a button left down on the server. The baseline device
        // is a Magic Keyboard trackpad, which has one button.
        let buttons = (ending ? [] : Self.pointerButtons(in: event?.buttonMask ?? [])).union(macButtons)
        indirectButtons = buttons
        deliver(pointerRouter.buttonsChanged(
            to: buttons,
            at: location.map(viewportPoint)
        ))
        return true
    }

    private static func pointerButtons(in mask: UIEvent.ButtonMask) -> Set<PointerButton> {
        var buttons: Set<PointerButton> = []
        if mask.contains(.primary) { buttons.insert(.left) }
        if mask.contains(.secondary) { buttons.insert(.right) }
        // Button 3 is the middle button on a mouse; a trackpad never reports
        // it, so this is only reached with real hardware attached.
        if mask.contains(.button(3)) { buttons.insert(.middle) }
        return buttons
    }

    // MARK: - Touch

    func setTouchMode(_ mode: TouchPointerMode) {
        guard mode != touchMode else { return }
        touchMode = mode
        // One finger belongs to the host in the other two modes, and a
        // double tap is a double click there, not a change of scale.
        viewportPan?.isEnabled = mode == .viewport
        viewportDoubleTap?.isEnabled = mode == .viewport
        directTrackpad.setEnabled(mode == .trackpad && isInputEnabled)
        directTouch.setEnabled(mode == .direct && isInputEnabled)
        if mode != .trackpad { directTrackpad.reset() }
        if mode != .direct { directTouch.reset() }
        liftTouches()
        directFingers.removeAll()
        directGoesAsTouch = false
    }

    /// Sends the held first finger: down where it landed, then where it is.
    private func sendHeldTouch() {
        heldTouchTimer?.invalidate()
        heldTouchTimer = nil
        guard let held = heldTouch else { return }
        heldTouch = nil
        remoteTouch(held.touch, phase: .down, at: held.location)
        remoteTouch(held.touch, phase: .move)
    }

    private func dropHeldTouch() {
        heldTouchTimer?.invalidate()
        heldTouchTimer = nil
        heldTouch = nil
    }

    /// Direct mode: where the finger is, as on a touch screen. A host that
    /// takes touches (Windows, GNOME) gets one finger as a touch - its own
    /// tap, press-and-hold and panning, as in the Windows App. Two fingers
    /// are the same on every host: the gesture goes on as the mouse one -
    /// scroll, right click, and zooming the view here. The first finger is
    /// held back `touchHoldBack` for that; a second finger later than that
    /// takes back the touch already sent. Any other host (a Mac, a logon screen
    /// before the touch channel opens) gets the mouse throughout.
    private func directBegan(_ touch: UITouch, event: UIEvent?) {
        if directFingers.isEmpty { directGoesAsTouch = inputSink?.acceptsTouch == true }
        directFingers.insert(ObjectIdentifier(touch))
        guard directGoesAsTouch else {
            directTouch.began(touch, in: self)
            return
        }
        if directFingers.count == 1 {
            heldTouch = (touch, touch.location(in: self))
            let timer = Timer(timeInterval: Self.touchHoldBack, repeats: false) { [weak self] _ in
                self?.sendHeldTouch()
            }
            RunLoop.main.add(timer, forMode: .common)
            heldTouchTimer = timer
            return
        }
        dropHeldTouch()
        cancelRemoteTouches()
        directGoesAsTouch = false
        let earlier = (event?.allTouches ?? []).filter {
            $0 !== touch && $0.type == .direct && directFingers.contains(ObjectIdentifier($0))
                && $0.phase != .ended && $0.phase != .cancelled
        }
        for finger in earlier { directTouch.began(finger, in: self) }
        directTouch.began(touch, in: self)
    }

    private func touchesFinished(_ touches: Set<UITouch>, cancelled: Bool) {
        for touch in touches where touch.type == .pencil {
            pen(touch, phase: .up)
        }
        for touch in touches where touch.type == .direct {
            switch touchMode {
            case .trackpad: directTrackpad.ended(touch, cancelled: cancelled)
            case .direct:
                if directGoesAsTouch {
                    // A tap quicker than the hold-back goes now, whole.
                    if heldTouch?.touch === touch {
                        if cancelled { dropHeldTouch() } else { sendHeldTouch() }
                    }
                    remoteTouch(touch, phase: cancelled ? .cancel : .up)
                } else {
                    directTouch.ended(touch, in: self, cancelled: cancelled)
                }
                directFingers.remove(ObjectIdentifier(touch))
            case .viewport: break
            }
        }
    }

    // MARK: - Windows touch and pen

    /// Every finger taken back from the host, without a tap.
    private func cancelRemoteTouches() {
        for contact in touchContacts.values {
            inputSink?.send(touch: TouchInput(contactID: contact.id, phase: .cancel, point: contact.pixel))
        }
        touchContacts.removeAll()
    }

    /// One finger as a Windows touch. Each finger keeps the lowest contact
    /// number free when it went down, as a touch screen numbers them.
    private func remoteTouch(_ touch: UITouch, phase: TouchInput.Phase, at location: CGPoint? = nil) {
        let key = ObjectIdentifier(touch)
        let pixel = viewportTransform.remotePixel(fromLocal: viewportPoint(location ?? touch.location(in: self)))
        switch phase {
        case .down:
            guard isInputEnabled, touchContacts[key] == nil else { return }
            let used = Set(touchContacts.values.map(\.id))
            guard let id = (0...UInt32(9)).first(where: { !used.contains($0) }) else { return }
            touchContacts[key] = (id, pixel)
            inputSink?.send(touch: TouchInput(contactID: id, phase: .down, point: pixel))
        case .move:
            guard isInputEnabled, let contact = touchContacts[key], contact.pixel != pixel else { return }
            touchContacts[key] = (contact.id, pixel)
            inputSink?.send(touch: TouchInput(contactID: contact.id, phase: .move, point: pixel))
        case .up, .cancel:
            guard let contact = touchContacts.removeValue(forKey: key) else { return }
            // A lift is owed whatever happened to the gate since.
            inputSink?.send(touch: TouchInput(contactID: contact.id, phase: phase, point: pixel))
        }
    }

    /// Apple Pencil as a pen: pressure from force, tilt from altitude and
    /// azimuth, rotation from roll where the pencil reports it.
    private func pen(_ touch: UITouch, phase: PenInput.Phase) {
        let key = ObjectIdentifier(touch)
        let pixel = viewportTransform.remotePixel(fromLocal: viewportPoint(touch.location(in: self)))
        let maximum = touch.maximumPossibleForce > 0 ? touch.maximumPossibleForce : 1
        let pressure = Double(min(max(touch.force / maximum, 0), 1))
        // Upright is altitude pi/2: no tilt. Leaning is split along the
        // azimuth into the two axes Windows asks for.
        let lean = Double.pi / 2 - Double(touch.altitudeAngle)
        let azimuth = Double(touch.azimuthAngle(in: self))
        let tiltX = Int((lean * cos(azimuth) * 180 / .pi).rounded())
        let tiltY = Int((lean * sin(azimuth) * 180 / .pi).rounded())
        let rotation: Int
        if #available(iOS 17.5, *) {
            rotation = Int((Double(touch.rollAngle) * 180 / .pi).rounded())
        } else {
            rotation = 0
        }
        func send(_ phase: PenInput.Phase) {
            inputSink?.send(pen: PenInput(
                phase: phase,
                point: pixel,
                pressure: phase == .up ? 0 : pressure,
                tiltX: tiltX,
                tiltY: tiltY,
                rotation: rotation
            ))
        }
        switch phase {
        case .down:
            guard isInputEnabled, penContact == nil else { return }
            penContact = (key, pixel)
            send(.down)
        case .move:
            guard isInputEnabled, penContact?.touch == key else { return }
            penContact = (key, pixel)
            send(.move)
        case .up:
            guard penContact?.touch == key else { return }
            penContact = nil
            send(.up)
        case .hover:
            guard isInputEnabled, penContact == nil else { return }
            send(.hover)
        }
    }

    /// The pencil hovering: where it would touch, and how it leans.
    private func penHover(at point: CGPoint, recognizer: UIHoverGestureRecognizer) {
        guard isInputEnabled, penContact == nil else { return }
        let pixel = viewportTransform.remotePixel(fromLocal: viewportPoint(point))
        var tiltX = 0
        var tiltY = 0
        if #available(iOS 16.4, *) {
            let lean = Double.pi / 2 - Double(recognizer.altitudeAngle)
            let azimuth = Double(recognizer.azimuthAngle(in: self))
            tiltX = Int((lean * cos(azimuth) * 180 / .pi).rounded())
            tiltY = Int((lean * sin(azimuth) * 180 / .pi).rounded())
        }
        inputSink?.send(pen: PenInput(phase: .hover, point: pixel, tiltX: tiltX, tiltY: tiltY))
    }

    /// Every finger and the pen lifted, for a closing gate or a mode change.
    private func liftTouches() {
        dropHeldTouch()
        cancelRemoteTouches()
        if let pen = penContact {
            inputSink?.send(pen: PenInput(phase: .up, point: pen.pixel))
            penContact = nil
        }
    }

    func movePointer(to point: CGPoint) {
        hoverLocation = point
        relativePointerPixel = nil
        positionCursorLayer()
        deliver(pointerRouter.moved(to: viewportPoint(point)))
    }

    func setTouchButtons(_ buttons: Set<PointerButton>, at point: CGPoint) {
        hoverLocation = point
        relativePointerPixel = nil
        positionCursorLayer()
        touchButtons = buttons
        deliver(pointerRouter.buttonsChanged(to: buttons, at: viewportPoint(point)))
    }

    // MARK: - Laptop deck

    /// Keys from the laptop deck's keyboard. Downs are dropped while the gate
    /// is closed; ups never are, because an up the host is owed has to arrive
    /// whatever happened to the gate in between.
    func sendLaptopKeys(_ events: [KeyboardInput]) {
        guard let inputSink else { return }
        for event in events where event.transition == .up || isInputEnabled {
            inputSink.send(event)
        }
    }

    /// Finger travel on the deck's trackpad, in points.
    func moveRemotePointer(dx: Double, dy: Double, speed: Double) {
        guard isInputEnabled, desktopSize.width > 1 || desktopSize.height > 1 else { return }
        let start = relativePointerPixel
            ?? pointerRouter.knownPixel
            ?? PixelPoint(x: desktopSize.width / 2, y: desktopSize.height / 2)
        let pixel = relativeMotion.next(
            from: start,
            dx: dx,
            dy: dy,
            // Not on screen here - the desktop is on another display - the
            // pointer goes at that display's scale.
            pixelsPerPoint: bounds.width < 1
                ? mirror?.pixelsPerPoint ?? 1
                : 1 / max(viewportTransform.scale, 0.01),
            speed: speed,
            desktopWidth: desktopSize.width,
            desktopHeight: desktopSize.height
        )
        relativePointerPixel = pixel
        hoverLocation = nil
        deliver(pointerRouter.moved(toPixel: pixel))
        keepRelativePointerInView()
        positionCursorLayer()
    }

    func setLaptopButton(_ button: PointerButton, pressed: Bool) {
        if pressed {
            laptopButtons.insert(button)
        } else {
            laptopButtons.remove(button)
        }
        anchorRelativePointer()
        deliver(pointerRouter.buttonsChanged(to: laptopButtons))
    }

    /// Tap to click: down and up around whatever the deck's buttons hold.
    func clickRemote(_ button: PointerButton) {
        anchorRelativePointer()
        deliver(pointerRouter.buttonsChanged(to: laptopButtons.union([button])))
        deliver(pointerRouter.buttonsChanged(to: laptopButtons))
    }

    func scrollRemote(dx: Double, dy: Double) {
        deliver(pointerRouter.scrolled(horizontal: dx, vertical: dy))
    }

    /// A click before the trackpad ever moved lands where the cursor is
    /// drawn, not at the desktop's origin.
    private func anchorRelativePointer() {
        guard pointerRouter.knownPixel == nil else { return }
        let centre = PixelPoint(x: desktopSize.width / 2, y: desktopSize.height / 2)
        relativePointerPixel = centre
        deliver(pointerRouter.moved(toPixel: centre))
        positionCursorLayer()
    }

    /// Zoomed in, the view follows the pointer the way a magnifier does, so
    /// the trackpad can reach the whole desktop without a pan gesture. With
    /// the software keyboard up it also follows it above the keyboard.
    private func keepRelativePointerInView() {
        guard let relativePointerPixel else { return }
        keepInView(relativePointerPixel)
    }

    private func keepInView(_ pixel: PixelPoint) {
        guard bounds.width >= 1 else { return }
        let covered = viewportTransform.occludedBottom > 0
        guard zoom > 1 || scaleMode == .oneToOne || covered else { return }
        let point = viewportTransform.localPoint(fromRemote: pixel)
        let margin = 24.0
        let bottom = viewportTransform.visibleHeight
        var shift = ViewportPoint.zero
        if point.x < margin { shift.x = margin - point.x }
        if point.x > bounds.width - margin { shift.x = bounds.width - margin - point.x }
        if point.y < margin { shift.y = margin - point.y }
        if point.y > bottom - margin { shift.y = bottom - margin - point.y }
        guard shift != .zero else { return }
        pan = ViewportPoint(x: pan.x + shift.x, y: pan.y + shift.y)
        updateTransform()
        setNeedsDisplay()
    }

    // MARK: - Software keyboard

    func setFollowsPointerAboveKeyboard(_ follows: Bool) {
        guard follows != followsPointerAboveKeyboard else { return }
        followsPointerAboveKeyboard = follows
        keyboardCoverChanged()
    }

    @objc private func keyboardFrameWillChange(_ notification: Notification) {
        guard let window,
              let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else {
            return
        }
        let screen = window.screen.bounds
        // Only a keyboard docked along the bottom covers a band of the view;
        // a floating or split one on an iPad is left to the user to move.
        let docked = end.maxY >= screen.maxY - 1 && end.width >= screen.width - 1
        let frame = convert(end, from: window.screen.coordinateSpace)
        setKeyboardOverlap(docked ? min(max(bounds.maxY - frame.minY, 0), bounds.height) : 0)
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        setKeyboardOverlap(0)
    }

    private func setKeyboardOverlap(_ overlap: CGFloat) {
        guard overlap != keyboardOverlap else { return }
        keyboardOverlap = overlap
        keyboardCoverChanged()
    }

    /// Lifts the desktop until the pointer clears the keyboard, or lets it
    /// fall back once the keyboard has gone.
    private func keyboardCoverChanged() {
        updateTransform()
        if let pixel = relativePointerPixel ?? pointerRouter.knownPixel {
            keepInView(pixel)
        }
        setNeedsDisplay()
    }

    // MARK: - Remote keyboard

    /// Required for `pressesBegan` to arrive at all: presses go to the first
    /// responder chain, and this view is a leaf rather than an ancestor of
    /// whatever SwiftUI would otherwise focus.
    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, transition: .down, to: super.pressesBegan, with: event)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        forward(presses, transition: .up, to: super.pressesEnded, with: event)
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // Analog force on a key that is already down. There is no transition
        // to send, but the press is still consumed rather than passed up,
        // because passing it up is what shows the input-source HUD.
        let unhandled = presses.filter { $0.key == nil }
        if !unhandled.isEmpty { super.pressesChanged(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        // A cancelled press has no reliable up of its own, so everything held
        // is released rather than only what this event names.
        releaseHeldKeys(reason: .pressesCancelled)
        let unhandled = presses.filter { $0.key == nil }
        if !unhandled.isEmpty { super.pressesCancelled(unhandled, with: event) }
    }

    /// Handled presses are deliberately not passed to `super`: that is the
    /// whole of `KEY-IME-02`. Presses without a key - a remote, a game
    /// controller button - are passed on untouched.
    private func forward(
        _ presses: Set<UIPress>,
        transition: InputTransition,
        to superImplementation: (Set<UIPress>, UIPressesEvent?) -> Void,
        with event: UIPressesEvent?
    ) {
        for press in presses {
            guard let key = press.key else { continue }
            apply(keyboard.receive(
                usage: UInt16(truncatingIfNeeded: key.keyCode.rawValue),
                transition: transition,
                from: .uiKit
            ))
        }
        publishDiagnostics()
        let unhandled = presses.filter { $0.key == nil }
        if !unhandled.isEmpty { superImplementation(unhandled, event) }
    }

    private func apply(_ output: KeyboardRouterOutput) {
        send(output)
        guard output.restartsRepeat else { return }
        armKeyRepeat(after: keyboard.repeatSettings.initialDelay)
    }

    private func send(_ output: KeyboardRouterOutput) {
        for key in output.events {
            inputSink?.send(key)
        }
    }

    private func receiveGameController(usage: UInt16, pressed: Bool) {
        apply(keyboard.receive(
            usage: usage,
            transition: pressed ? .down : .up,
            from: .gameController
        ))
        publishDiagnostics()
    }

    /// The Mac's keys, from AppKit (`MacKeyboardCapture`): the same usages
    /// `pressesBegan` would carry, for the keys UIKit does not deliver there.
    private func receiveMac(usage: UInt16, transition: InputTransition) {
        apply(keyboard.receive(usage: usage, transition: transition, from: .uiKit))
        publishDiagnostics()
    }

    /// A Mac right (1) or middle (2) click, pressed where the pointer is
    /// hovering. A click anywhere else - another window, a sheet - is left
    /// to the Mac.
    private func receiveMacButton(_ number: UInt16, pressed: Bool) -> Bool {
        let button: PointerButton
        switch number {
        case 1: button = .right
        case 2: button = .middle
        default: return false
        }
        guard isInputEnabled, window?.isKeyWindow == true, let hoverLocation else {
            // A release still lands, so nothing stays held on the host.
            guard !pressed, macButtons.contains(button) else { return false }
            macButtons.remove(button)
            indirectButtons.remove(button)
            deliver(pointerRouter.buttonsChanged(to: indirectButtons, at: nil))
            return true
        }
        if pressed { macButtons.insert(button) } else { macButtons.remove(button) }
        if pressed { indirectButtons.insert(button) } else { indirectButtons.remove(button) }
        deliver(pointerRouter.buttonsChanged(to: indirectButtons, at: viewportPoint(hoverLocation)))
        return true
    }

    /// A trackpad or wheel scroll over the surface, for a Mac server that
    /// takes it natively. Anything else stays with UIKit's pan.
    private func receiveMacScroll(_ input: MacScrollInput) -> Bool {
        guard isInputEnabled, window?.isKeyWindow == true, hoverLocation != nil,
              let sink = inputSink as? any MacInputSink, sink.acceptsMacScroll
        else { return false }
        sink.send(macScroll: input)
        return true
    }

    private func gameControllerKeyboardDisconnected() {
        stopKeyRepeat()
        send(keyboard.sourceDisconnected(.gameController))
        publishDiagnostics()
    }

    /// One pending fire at a time, replaced rather than stacked. `.common` so
    /// a held key keeps repeating while a gesture is tracking.
    private func armKeyRepeat(after delay: TimeInterval) {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
        guard isInputEnabled, keyboard.repeatTarget != nil else { return }
        let timer = Timer(timeInterval: delay, repeats: false) { _ in
            MainActor.assumeIsolated { [weak self] in self?.fireKeyRepeat() }
        }
        RunLoop.main.add(timer, forMode: .common)
        keyRepeatTimer = timer
    }

    private func fireKeyRepeat() {
        // Re-checked at every fire rather than trusted from arming time: a
        // release or a scene change can happen underneath a pending timer, and
        // a repeat must never outlive the down it extends.
        guard isInputEnabled, let key = keyboard.repeatDown() else {
            keyRepeatTimer?.invalidate()
            keyRepeatTimer = nil
            return
        }
        inputSink?.send(key)
        armKeyRepeat(after: keyboard.repeatSettings.interval)
    }

    private func stopKeyRepeat() {
        keyRepeatTimer?.invalidate()
        keyRepeatTimer = nil
    }

    func releaseHeldKeys(reason: InputReleaseReason = .focusLost) {
        stopKeyRepeat()
        MacKeyboardCapture.shared.releaseMacKeys(for: self)
        send(keyboard.releaseAll(reason: reason))
        publishDiagnostics()
    }

    override func resignFirstResponder() -> Bool {
        let wasFirstResponder = isFirstResponder
        let result = super.resignFirstResponder()
        // Losing the responder means no more `pressesEnded`, so anything held
        // has to be released now or it stays down on the server.
        if wasFirstResponder, result { releaseHeldKeys(reason: .focusLost) }
        return result
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else {
            HardwareKeyboardMonitor.shared.release(self)
            MacKeyboardCapture.shared.releaseMacKeys(for: self)
            MacKeyboardCapture.shared.release(self)
            releaseHeldButtons()
            releaseHeldKeys(reason: .surfaceRemoved)
            return
        }
        HardwareKeyboardMonitor.shared.claim(self, target: .init(
            onKey: { [weak self] usage, pressed in
                self?.receiveGameController(usage: usage, pressed: pressed)
            },
            onDisconnect: { [weak self] in
                self?.gameControllerKeyboardDisconnected()
            }
        ))
        MacKeyboardCapture.shared.claim(self, target: .init(
            isCapturing: { [weak self] in
                guard let self else { return false }
                return isFirstResponder && window?.isKeyWindow == true && keyboard.isGateOpen
            },
            deliver: { [weak self] usage, transition in
                self?.receiveMac(usage: usage, transition: transition)
            },
            pressButton: { [weak self] button, pressed in
                self?.receiveMacButton(button, pressed: pressed) ?? false
            },
            macSink: { [weak self] in
                self?.inputSink as? any MacInputSink
            },
            scroll: { [weak self] input in
                self?.receiveMacScroll(input) ?? false
            }
        ))
        captureKeyboardIfPossible()
    }

    // MARK: - Remote cursor

    private func applyRemoteCursor() {
        let cursor = cursorStore?.cursor ?? .systemDefault
        guard cursor != remoteCursor else { return }
        remoteCursor = cursor
        if case .shape(let image) = cursor {
            remoteCursorImage = Self.cgImage(image)
        } else {
            remoteCursorImage = nil
        }
        cursorLayer.contents = remoteCursorImage
        pointerInteraction?.invalidate()
        positionCursorLayer()
    }

    /// The remote cursor is drawn at the remote desktop's scale, so a 32-pixel
    /// arrow shrinks with the desktop when fitted and grows when zoomed - the
    /// same size relative to the remote content as on a real monitor.
    private func positionCursorLayer() {
        publishCursorToMirror()
        let transform = viewportTransform
        let location: CGPoint
        if let relativePointerPixel {
            let point = transform.localPoint(fromRemote: relativePointerPixel)
            location = CGPoint(x: point.x, y: point.y)
        } else if let hoverLocation {
            // At the pixel the host was sent rather than the point it was
            // sent from: a resize, a zoom or the keyboard's lift moves the
            // desktop under a pointer that has not moved on it.
            if let pixel = pointerRouter.knownPixel {
                let point = transform.localPoint(fromRemote: pixel)
                location = CGPoint(x: point.x, y: point.y)
            } else {
                location = hoverLocation
            }
        } else {
            cursorLayer.isHidden = true
            return
        }
        let frame: CGRect
        switch remoteCursor {
        case .shape(let image):
            let scale = transform.contentRect.width / Double(max(transform.desktopWidth, 1))
            frame = CGRect(
                x: location.x - CGFloat(Double(image.hotspotX) * scale),
                y: location.y - CGFloat(Double(image.hotspotY) * scale),
                width: CGFloat(Double(image.width) * scale),
                height: CGFloat(Double(image.height) * scale)
            )
        case .systemDefault where relativePointerPixel != nil:
            // The system pointer stands in for the default arrow only when it
            // is where the remote pointer is; moved from the trackpad it is
            // not, so an arrow is drawn instead.
            cursorLayer.contents = Self.fallbackArrow
            frame = CGRect(origin: location, size: Self.fallbackArrowSize)
        default:
            cursorLayer.isHidden = true
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = frame
        cursorLayer.isHidden = false
        CATransaction.commit()
    }

    /// Where the pointer is on the desktop, for a mirror: it draws the
    /// cursor at its own scale.
    private func publishCursorToMirror() {
        guard let mirror else { return }
        let pixel = relativePointerPixel ?? pointerRouter.knownPixel
        switch remoteCursor {
        case .shape(let image):
            mirror.publishCursor(
                pixel: pixel.map { CGPoint(x: $0.x, y: $0.y) },
                image: remoteCursorImage,
                hotspot: CGPoint(x: Int(image.hotspotX), y: Int(image.hotspotY)),
                pixelSize: CGSize(width: Int(image.width), height: Int(image.height))
            )
        case .systemDefault:
            mirror.publishCursor(
                pixel: pixel.map { CGPoint(x: $0.x, y: $0.y) },
                image: Self.fallbackArrow,
                hotspot: .zero,
                pixelSize: .zero
            )
        case .hidden:
            mirror.publishCursor(pixel: nil, image: nil, hotspot: .zero, pixelSize: .zero)
        }
    }

    private static let fallbackArrowSize = CGSize(width: 13, height: 20)

    private static let fallbackArrow: CGImage? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let renderer = UIGraphicsImageRenderer(size: fallbackArrowSize, format: format)
        return renderer.image { _ in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 1, y: 1))
            path.addLine(to: CGPoint(x: 1, y: 16))
            path.addLine(to: CGPoint(x: 4.8, y: 12.6))
            path.addLine(to: CGPoint(x: 7.4, y: 18.4))
            path.addLine(to: CGPoint(x: 9.8, y: 17.3))
            path.addLine(to: CGPoint(x: 7.3, y: 11.8))
            path.addLine(to: CGPoint(x: 12, y: 11.8))
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 1.2
            UIColor.white.setFill()
            path.fill()
            UIColor.black.setStroke()
            path.stroke()
        }.cgImage
    }()

    private static func cgImage(_ image: RemoteCursorImage) -> CGImage? {
        guard let provider = CGDataProvider(data: image.pixels as CFData) else { return nil }
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    func pointerInteraction(
        _ interaction: UIPointerInteraction,
        styleFor region: UIPointerRegion
    ) -> UIPointerStyle? {
        switch remoteCursor {
        case .systemDefault: return nil
        // Hidden either way: the remote shape is drawn by the layer, and a
        // server that hid its pointer gets no pointer here either.
        case .hidden, .shape: return .hidden()
        }
    }

    func setKeyboardCaptureSuppressed(_ suppressed: Bool) {
        guard suppressed != isKeyboardCaptureSuppressed else { return }
        isKeyboardCaptureSuppressed = suppressed
        if !suppressed { captureKeyboardIfPossible() }
    }

    private func captureKeyboardIfPossible() {
        guard isInputEnabled, !isKeyboardCaptureSuppressed, window != nil,
              !isFirstResponder else { return }
        _ = becomeFirstResponder()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        updateTransform()
    }

    func draw(in view: MTKView) {
        guard hasPresentedAFrame,
              let desktopTexture,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        var rect = normalisedContentRect()
        var source = SIMD4<Float>(
            0, 0,
            Float(min(Double(transformDesktopSize.width) / Double(max(desktopTexture.width, 1)), 1)),
            Float(min(Double(transformDesktopSize.height) / Double(max(desktopTexture.height, 1)), 1))
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        encoder.setVertexBytes(&source, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
        encoder.setFragmentTexture(desktopTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastSubmittedCommandBuffer = commandBuffer
    }

    /// (left, top, right, bottom) in Metal's normalised device coordinates,
    /// where y grows upwards and the viewport's y grows downwards.
    private func normalisedContentRect() -> SIMD4<Float> {
        let content = viewportTransform.contentRect
        let width = max(viewportTransform.viewport.width, 1)
        let height = max(viewportTransform.viewport.height, 1)
        return SIMD4<Float>(
            Float(2 * content.x / width - 1),
            Float(1 - 2 * content.y / height),
            Float(2 * content.maxX / width - 1),
            Float(1 - 2 * content.maxY / height)
        )
    }
}
