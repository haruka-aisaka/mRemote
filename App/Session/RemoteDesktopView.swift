import MetalKit
import QuartzCore
import UIKit
import SessionCore

/// The Metal surface the remote desktop is drawn on.
///
/// docs/architecture.md section 6 is the specification: the protocol worker
/// copies a BGRA surface into `LatestDesktopFrameStore`, the store raises one
/// coalesced signal, and this view uploads only the damaged region before
/// presenting. Metal composites and scales; it never decodes.
///
/// Input is not this view's job yet. Phase 3 adds the key and pointer capture;
/// the gestures here move the viewport, which is what makes a 1920x1080
/// desktop usable on an iPad before any of that exists.
@MainActor
final class RemoteDesktopView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate {
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

    private let frameStore: LatestDesktopFrameStore
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

    private(set) var viewportTransform: ViewportTransform

    init(frameStore: LatestDesktopFrameStore, scaleMode: InitialScale) {
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
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.scaleMode = scaleMode
        viewportTransform = ViewportTransform(
            desktopWidth: 1,
            desktopHeight: 1,
            viewport: .zero,
            scaleMode: scaleMode
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

        let drag = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        drag.delegate = self
        addGestureRecognizer(drag)

        let doubleTap = UITapGestureRecognizer(
            target: self,
            action: #selector(handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        attachToFrameStore()
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
    }

    deinit {
        // `deinit` is nonisolated, so the store's signal is cleared here
        // through the store itself rather than by touching the view.
        frameStore.setSignal(nil)
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
        onTransformChange?(viewportTransform)
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
