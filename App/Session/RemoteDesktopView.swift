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
/// Two input worlds share this view and they do not overlap. An indirect
/// pointer - a trackpad or a mouse - drives the *remote* pointer: hover moves
/// it, a click is a button, a two-finger scroll is a wheel. Direct touches
/// drive the *local* viewport: one finger pans, pinch zooms, a double tap
/// switches between fit and 100%. Sharing a gesture between the two is what
/// makes a tablet RDP client feel unpredictable, so nothing here does.
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
    UIPointerInteractionDelegate {
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
    vertex RasterizerData desktopVertex(
        uint vertexID [[vertex_id]],
        constant float4 &rect [[buffer(0)]]) {
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
        output.textureCoordinate = corner;
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
    private var hasPresentedAFrame = false
    private var pointerRouter: PointerInputRouter
    private var keyboard = KeyboardEventArbiter()
    private var keyRepeatTimer: Timer?
    /// Buttons the platform reports as held right now. Kept so a touch phase
    /// that carries no button mask does not read as "everything released".
    private var indirectButtons: Set<PointerButton> = []
    /// False until the surface is configured, so nothing is delivered before
    /// the workspace has said whether the session can carry it.
    private var isInputEnabled = false

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
        accessibilityLabel = "リモートデスクトップ"
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

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(doubleTap)

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
    }

    private func waitForSubmittedTextureRead() {
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
        let scale = window?.screen.scale ?? contentScaleFactor
        onRenderSizeChange?(
            Int((bounds.width * scale).rounded()),
            Int((bounds.height * scale).rounded())
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
            desktopWidth: desktopSize.width,
            desktopHeight: desktopSize.height,
            viewport: ViewportSize(width: bounds.width, height: bounds.height),
            scaleMode: scaleMode,
            zoom: zoom,
            pan: pan
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
        }
        onTransformChange?(viewportTransform)
        positionCursorLayer()
    }

    @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            zoomOrigin = zoom
        case .changed, .ended:
            zoom = ViewportTransform.clampZoom(zoomOrigin * Double(recognizer.scale))
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
        indirectButtons = []
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
        switch recognizer.state {
        case .began, .changed:
            hoverLocation = recognizer.location(in: self)
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
            super.touchesBegan(touches, with: event)
            return
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard handleIndirectPointer(touches, event: event, ending: false) else {
            super.touchesMoved(touches, with: event)
            return
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard handleIndirectPointer(touches, event: event, ending: true) else {
            super.touchesEnded(touches, with: event)
            return
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard handleIndirectPointer(touches, event: event, ending: true) else {
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
            positionCursorLayer()
        }
        // An ending touch releases everything rather than trusting the mask,
        // which may still name the button that is lifting. On a two-button
        // chord that releases one button, this releases both and the next
        // event presses the survivor again - a visible flicker, but the
        // alternative is a button left down on the server. The baseline device
        // is a Magic Keyboard trackpad, which has one button.
        let buttons = ending ? [] : Self.pointerButtons(in: event?.buttonMask ?? [])
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
        captureKeyboardIfPossible()
    }

    // MARK: - Remote cursor

    private func applyRemoteCursor() {
        let cursor = cursorStore?.cursor ?? .systemDefault
        guard cursor != remoteCursor else { return }
        remoteCursor = cursor
        if case .shape(let image) = cursor {
            cursorLayer.contents = Self.cgImage(image)
        } else {
            cursorLayer.contents = nil
        }
        pointerInteraction?.invalidate()
        positionCursorLayer()
    }

    /// The remote cursor is drawn at the remote desktop's scale, so a 32-pixel
    /// arrow shrinks with the desktop when fitted and grows when zoomed - the
    /// same size relative to the remote content as on a real monitor.
    private func positionCursorLayer() {
        guard case .shape(let image) = remoteCursor, let hoverLocation else {
            cursorLayer.isHidden = true
            return
        }
        let transform = viewportTransform
        let scale = transform.contentRect.width / Double(max(transform.desktopWidth, 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        cursorLayer.frame = CGRect(
            x: hoverLocation.x - CGFloat(Double(image.hotspotX) * scale),
            y: hoverLocation.y - CGFloat(Double(image.hotspotY) * scale),
            width: CGFloat(Double(image.width) * scale),
            height: CGFloat(Double(image.height) * scale)
        )
        cursorLayer.isHidden = false
        CATransaction.commit()
    }

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

    private func captureKeyboardIfPossible() {
        guard isInputEnabled, window != nil, !isFirstResponder else { return }
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
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
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
