import MetalKit
import QuartzCore
import UIKit

struct BGRADesktopUpdate {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let pixels: Data
    let dirtyRectangles: [CGRect]
}

enum DesktopFixturePreset: Int, CaseIterable {
    case hd720
    case fullHD1080
    case ultraHD4K

    var title: String {
        switch self {
        case .hd720: return "720p"
        case .fullHD1080: return "1080p"
        case .ultraHD4K: return "4K"
        }
    }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .hd720: return (1280, 720)
        case .fullHD1080: return (1920, 1080)
        case .ultraHD4K: return (3840, 2160)
        }
    }
}

@MainActor
final class RemoteSurfaceView: MTKView, MTKViewDelegate, UIGestureRecognizerDelegate {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct RasterizerData {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    vertex RasterizerData phase0Vertex(uint vertexID [[vertex_id]]) {
        const float2 positions[] = {
            float2(-1.0, -1.0), float2(1.0, -1.0),
            float2(-1.0, 1.0), float2(1.0, 1.0)
        };
        const float2 coordinates[] = {
            float2(0.0, 1.0), float2(1.0, 1.0),
            float2(0.0, 0.0), float2(1.0, 0.0)
        };
        RasterizerData output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        output.textureCoordinate = coordinates[vertexID];
        return output;
    }

    fragment float4 phase0Fragment(
        RasterizerData input [[stage_in]],
        texture2d<float> desktop [[texture(0)]]) {
        constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
        return desktop.sample(textureSampler, input.textureCoordinate);
    }
    """

    var onDiagnostic: ((String) -> Void)?
    var onFrameStatus: ((String) -> Void)?
    var allowsHardwareInput = true

    private let router: HarnessInputRouter
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var desktopTexture: MTLTexture?
    private var lastSubmittedCommandBuffer: MTLCommandBuffer?
    private(set) var remoteDesktopSize = CGSize(width: 1, height: 1)

    private var uiKitButtonMask: UIEvent.ButtonMask = []
    private var gcVirtualCursor = CGPoint.zero
    private var lastUIKitPointer = CGPoint.zero
    private var testPixels = Data()
    private var testPreset: DesktopFixturePreset = .hd720
    private var testWidth = DesktopFixturePreset.hd720.dimensions.width
    private var testHeight = DesktopFixturePreset.hd720.dimensions.height
    private var testFrameIndex = 0
    private var previousTestRectangle: CGRect?

    private var applyCount = 0
    private var presentedCount = 0
    private var lastApplyMilliseconds = 0.0
    private var lastGPUWaitMilliseconds = 0.0
    private var lastPresentMilliseconds: Double?
    private var lastUploadedRectangleCount = 0
    private var lastTextureWasRecreated = false

    override var canBecomeFirstResponder: Bool { true }

    init(router: HarnessInputRouter) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal is required by the Phase 0 harness")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        descriptor.vertexFunction = library?.makeFunction(name: "phase0Vertex")
        descriptor.fragmentFunction = library?.makeFunction(name: "phase0Fragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            fatalError("Could not create the Phase 0 Metal render pipeline")
        }

        self.router = router
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        super.init(frame: .zero, device: device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0.015, 0.02, 0.03, 1)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        delegate = self
        layer.cornerRadius = 10
        layer.borderWidth = 1
        layer.borderColor = UIColor.tertiaryLabel.cgColor
        clipsToBounds = true
        accessibilityLabel = "Metal remote desktop surface"
        isMultipleTouchEnabled = true

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleHover(_:)))
        hover.delegate = self
        addGestureRecognizer(hover)

        let scroll = UIPanGestureRecognizer(target: self, action: #selector(handleScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.cancelsTouchesInView = false
        scroll.delegate = self
        addGestureRecognizer(scroll)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func loadInitialTestFrame() {
        loadTestFrame(.hd720)
    }

    func loadTestFrame(_ preset: DesktopFixturePreset) {
        testPreset = preset
        let dimensions = preset.dimensions
        testWidth = dimensions.width
        testHeight = dimensions.height
        testFrameIndex = 0
        previousTestRectangle = nil
        testPixels = makeTestPixels()
        let update = BGRADesktopUpdate(
            width: testWidth,
            height: testHeight,
            bytesPerRow: testWidth * 4,
            pixels: testPixels,
            dirtyRectangles: [CGRect(x: 0, y: 0, width: testWidth, height: testHeight)]
        )
        do {
            try apply(update)
        } catch {
            onDiagnostic?("\(preset.title) BGRA fixture failed: \(error)")
        }
    }

    func applyMovingDirtyTestUpdate() {
        testFrameIndex += 1
        let rectangle = CGRect(
            x: 40 + ((testFrameIndex * 83) % (testWidth - 240)),
            y: 40 + ((testFrameIndex * 47) % (testHeight - 180)),
            width: 200,
            height: 140
        )
        var dirty = [rectangle]
        if let previousTestRectangle {
            paintTestRegion(previousTestRectangle, highlighted: false)
            dirty.append(previousTestRectangle)
        }
        paintTestRegion(rectangle, highlighted: true)
        previousTestRectangle = rectangle

        do {
            try apply(BGRADesktopUpdate(
                width: testWidth,
                height: testHeight,
                bytesPerRow: testWidth * 4,
                pixels: testPixels,
                dirtyRectangles: dirty
            ))
        } catch {
            onDiagnostic?("dirty BGRA update failed: \(error)")
        }
    }

    /// Copies validated app-owned bytes into the texture. A FreeRDP callback
    /// must copy its short-lived buffer to Data before constructing this value.
    func apply(_ update: BGRADesktopUpdate) throws {
        let applyStarted = CACurrentMediaTime()
        lastGPUWaitMilliseconds = waitForSubmittedTextureRead()
        let validation = try BGRADesktopUpdateValidator.validate(
            width: update.width,
            height: update.height,
            bytesPerRow: update.bytesPerRow,
            pixelCount: update.pixels.count,
            dirtyRectangles: update.dirtyRectangles
        )

        let textureNeedsRecreation = desktopTexture?.width != update.width
            || desktopTexture?.height != update.height
        if textureNeedsRecreation {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: update.width,
                height: update.height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = [.shaderRead]
            guard let texture = device?.makeTexture(descriptor: descriptor) else {
                throw BGRADesktopUpdateError.metalTextureAllocationFailed
            }
            desktopTexture = texture
            remoteDesktopSize = CGSize(width: update.width, height: update.height)
            gcVirtualCursor = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        // A newly allocated texture has undefined contents. Even when the
        // callback describes a partial dirty region, seed the whole texture
        // from the validated app-owned framebuffer on first use/resize.
        let uploadedRectangles = validation.rectanglesForTexture(
            requiresFullSeed: textureNeedsRecreation
        )
        try update.pixels.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress, let desktopTexture else {
                throw BGRADesktopUpdateError.truncatedBuffer(
                    required: validation.requiredBytes,
                    actual: 0
                )
            }
            for rect in uploadedRectangles {
                let sourceOffset = rect.y * update.bytesPerRow + rect.x * 4
                desktopTexture.replace(
                    region: MTLRegionMake2D(rect.x, rect.y, rect.width, rect.height),
                    mipmapLevel: 0,
                    withBytes: baseAddress.advanced(by: sourceOffset),
                    bytesPerRow: update.bytesPerRow
                )
            }
        }

        applyCount += 1
        lastApplyMilliseconds = (CACurrentMediaTime() - applyStarted) * 1_000
        lastUploadedRectangleCount = uploadedRectangles.count
        lastTextureWasRecreated = textureNeedsRecreation
        publishFrameStatus()
        onDiagnostic?(
            String(
                format: "frame apply#%d %@ %d×%d uploadRects=%d cpu+wait=%.3fms gpuWait=%.3fms texture=%@",
                applyCount,
                testPreset.title,
                update.width,
                update.height,
                uploadedRectangles.count,
                lastApplyMilliseconds,
                lastGPUWaitMilliseconds,
                textureNeedsRecreation ? "new/full" : "reuse"
            )
        )
        setNeedsDisplay()
    }

    func receiveGCMouseDelta(horizontal: Double, vertical: Double) {
        if gcVirtualCursor == .zero {
            gcVirtualCursor = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        // GameController reports positive Y upward; UIKit points grow downward.
        gcVirtualCursor.x = min(max(gcVirtualCursor.x + horizontal, bounds.minX), bounds.maxX)
        gcVirtualCursor.y = min(max(gcVirtualCursor.y - vertical, bounds.minY), bounds.maxY)
        router.pointer.receive(PointerInputEvent(
            payload: .move(remote: remotePoint(from: gcVirtualCursor)),
            source: .gameController,
            uptime: ProcessInfo.processInfo.systemUptime
        ))
    }

    func currentGCMouseRemotePoint() -> CGPoint {
        remotePoint(from: gcVirtualCursor == .zero
            ? CGPoint(x: bounds.midX, y: bounds.midY)
            : gcVirtualCursor)
    }

    override func becomeFirstResponder() -> Bool {
        guard allowsHardwareInput, UIApplication.shared.applicationState == .active else {
            onDiagnostic?("RDP surface focus ignored while capture is unavailable")
            return false
        }
        let result = super.becomeFirstResponder()
        if result {
            router.setHardwareGate(open: true, reason: "RDP surface focused")
            onDiagnostic?("RDP surface became first responder (not UIKeyInput)")
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let wasFirstResponder = isFirstResponder
        let result = super.resignFirstResponder()
        if wasFirstResponder, result {
            router.setHardwareGate(
                open: false,
                reason: "RDP surface resigned first responder"
            )
            onDiagnostic?("RDP surface resigned first responder")
        }
        return result
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        routePresses(presses, transition: .down)
        let unhandled = presses.filter { $0.key == nil }
        if !unhandled.isEmpty { super.pressesBegan(Set(unhandled), with: event) }
    }

    override func pressesChanged(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let handledCount = presses.reduce(into: 0) { count, press in
            if press.key != nil { count += 1 }
        }
        if handledCount > 0 {
            onDiagnostic?("UIKit pressesChanged consumed count=\(handledCount); no remote repeat")
        }
        let unhandled = presses.filter { $0.key == nil }
        if !unhandled.isEmpty { super.pressesChanged(Set(unhandled), with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        routePresses(presses, transition: .up)
        let unhandled = presses.filter { $0.key == nil }
        if !unhandled.isEmpty { super.pressesEnded(Set(unhandled), with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        routePresses(presses, transition: .cancel)
        router.releaseAll(reason: "UIKit pressesCancelled")
        let unhandled = presses.filter { $0.key == nil }
        if !unhandled.isEmpty { super.pressesCancelled(Set(unhandled), with: event) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        _ = becomeFirstResponder()
        processUIKitPointerEvent(touches: touches, event: event, ending: false, cancelled: false)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        processUIKitPointerEvent(touches: touches, event: event, ending: false, cancelled: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        processUIKitPointerEvent(touches: touches, event: event, ending: true, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        processUIKitPointerEvent(touches: touches, event: event, ending: true, cancelled: true)
    }

    @objc private func handleHover(_ recognizer: UIHoverGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let point = recognizer.location(in: self)
        router.pointer.receive(PointerInputEvent(
            payload: .move(remote: remotePoint(from: point)),
            source: .uiKit,
            uptime: ProcessInfo.processInfo.systemUptime
        ))
    }

    @objc private func handleScroll(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .began || recognizer.state == .changed else { return }
        let delta = recognizer.translation(in: self)
        guard delta != .zero else { return }
        recognizer.setTranslation(.zero, in: self)
        router.pointer.receive(PointerInputEvent(
            payload: .scroll(horizontal: Double(delta.x), vertical: Double(delta.y)),
            source: .uiKit,
            uptime: ProcessInfo.processInfo.systemUptime
        ))
    }

    private func routePresses(_ presses: Set<UIPress>, transition: KeyTransition) {
        for press in presses {
            guard let key = press.key else { continue }
            let objectiveCUsage = UInt16(truncatingIfNeeded: MRHIDUsageFromUIKey(key))
            #if DEBUG
            let swiftUsage = UInt16(truncatingIfNeeded: key.keyCode.rawValue)
            if objectiveCUsage != swiftUsage {
                onDiagnostic?(
                    String(
                        format: "UIKey adapter mismatch objc=0x%02X swift=0x%02X",
                        objectiveCUsage, swiftUsage
                    )
                )
            }
            #endif
            router.keyboard.receive(HardwareKeyEvent(
                usage: objectiveCUsage,
                transition: transition,
                source: .uiKit,
                uptime: press.timestamp
            ))
        }
    }

    private func processUIKitPointerEvent(
        touches: Set<UITouch>,
        event: UIEvent?,
        ending: Bool,
        cancelled: Bool
    ) {
        let containsPointer = touches.contains { $0.type == .indirectPointer }
        guard containsPointer || !uiKitButtonMask.isEmpty || !(event?.buttonMask.isEmpty ?? true) else {
            return
        }

        if let touch = touches.first {
            lastUIKitPointer = touch.location(in: self)
            router.pointer.receive(PointerInputEvent(
                payload: .move(remote: remotePoint(from: lastUIKitPointer)),
                source: .uiKit,
                uptime: ProcessInfo.processInfo.systemUptime
            ))
        }

        var nextMask = event?.buttonMask ?? []
        if ending { nextMask = [] }
        let transitionForRelease: KeyTransition = cancelled ? .cancel : .up
        updateUIKitButton(.left, flag: .primary, nextMask: nextMask, release: transitionForRelease)
        updateUIKitButton(.right, flag: .secondary, nextMask: nextMask, release: transitionForRelease)
        uiKitButtonMask = nextMask
    }

    private func updateUIKitButton(
        _ button: PointerButton,
        flag: UIEvent.ButtonMask,
        nextMask: UIEvent.ButtonMask,
        release: KeyTransition
    ) {
        let wasPressed = uiKitButtonMask.contains(flag)
        let isPressed = nextMask.contains(flag)
        guard wasPressed != isPressed else { return }
        router.pointer.receive(PointerInputEvent(
            payload: .button(
                button,
                isPressed ? .down : release,
                remote: remotePoint(from: lastUIKitPointer == .zero
                    ? CGPoint(x: bounds.midX, y: bounds.midY)
                    : lastUIKitPointer)
            ),
            source: .uiKit,
            uptime: ProcessInfo.processInfo.systemUptime
        ))
    }

    private func remotePoint(from localPoint: CGPoint) -> CGPoint {
        let content = aspectFitRectangle(in: bounds, contentSize: remoteDesktopSize)
        guard content.width > 0, content.height > 0 else { return .zero }
        let normalizedX = min(max((localPoint.x - content.minX) / content.width, 0), 1)
        let normalizedY = min(max((localPoint.y - content.minY) / content.height, 0), 1)
        return CGPoint(
            x: normalizedX * max(remoteDesktopSize.width - 1, 0),
            y: normalizedY * max(remoteDesktopSize.height - 1, 0)
        )
    }

    private func aspectFitRectangle(in bounds: CGRect, contentSize: CGSize) -> CGRect {
        guard bounds.width > 0, bounds.height > 0,
              contentSize.width > 0, contentSize.height > 0 else { return .zero }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let size = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2,
            y: bounds.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private func makeTestPixels() -> Data {
        var data = Data(count: testWidth * testHeight * 4)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let pixels = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<testHeight {
                for x in 0..<testWidth {
                    let offset = (y * testWidth + x) * 4
                    let checker = ((x / 80) + (y / 80)).isMultiple(of: 2)
                    pixels[offset] = UInt8(checker ? 118 : 90)
                    pixels[offset + 1] = UInt8(checker ? 84 : 58)
                    pixels[offset + 2] = UInt8(checker ? 38 : 24)
                    pixels[offset + 3] = 255
                }
            }
        }
        return data
    }

    private func paintTestRegion(_ rectangle: CGRect, highlighted: Bool) {
        let bounds = CGRect(x: 0, y: 0, width: testWidth, height: testHeight)
        let clipped = rectangle.integral.intersection(bounds)
        guard !clipped.isNull, !clipped.isEmpty,
              let minX = Int(exactly: clipped.minX),
              let minY = Int(exactly: clipped.minY),
              let maxX = Int(exactly: clipped.maxX),
              let maxY = Int(exactly: clipped.maxY) else { return }

        testPixels.withUnsafeMutableBytes { rawBuffer in
            guard let pixels = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in minY..<maxY {
                for x in minX..<maxX {
                    let offset = (y * testWidth + x) * 4
                    if highlighted {
                        pixels[offset] = 44
                        pixels[offset + 1] = UInt8(75 + (testFrameIndex % 80))
                        pixels[offset + 2] = UInt8(190 + (testFrameIndex % 50))
                    } else {
                        let checker = ((x / 80) + (y / 80)).isMultiple(of: 2)
                        pixels[offset] = UInt8(checker ? 118 : 90)
                        pixels[offset + 1] = UInt8(checker ? 84 : 58)
                        pixels[offset + 2] = UInt8(checker ? 38 : 24)
                    }
                    pixels[offset + 3] = 255
                }
            }
        }
    }

    private func publishFrameStatus() {
        let present = lastPresentMilliseconds.map {
            String(format: "present#%d %.3fms", presentedCount, $0)
        } ?? "present#0 pending"
        onFrameStatus?(
            String(
                format: "%@ %d×%d frame=%d | apply#%d %.3fms (wait %.3f) rects=%d%@ | %@",
                testPreset.title,
                testWidth,
                testHeight,
                testFrameIndex,
                applyCount,
                lastApplyMilliseconds,
                lastGPUWaitMilliseconds,
                lastUploadedRectangleCount,
                lastTextureWasRecreated ? " full-seed" : "",
                present
            )
        )
    }

    /// The Phase 0 harness intentionally uses one shared texture. Serialize a
    /// CPU replace against all earlier reads on the same command queue. This
    /// blocking seam is safe for the manual fixture and makes its cost visible;
    /// production should replace it with immutable multi-buffer slots.
    private func waitForSubmittedTextureRead() -> Double {
        guard let commandBuffer = lastSubmittedCommandBuffer else { return 0 }
        let waitStarted = CACurrentMediaTime()
        switch commandBuffer.status {
        case .completed, .error:
            break
        case .notEnqueued, .enqueued, .committed, .scheduled:
            commandBuffer.waitUntilCompleted()
        @unknown default:
            commandBuffer.waitUntilCompleted()
        }
        lastSubmittedCommandBuffer = nil
        if commandBuffer.status == .error {
            onDiagnostic?("previous Metal command failed: \(commandBuffer.error?.localizedDescription ?? "unknown")")
        }
        return (CACurrentMediaTime() - waitStarted) * 1_000
    }

    private func recordPresentation(frame: Int, elapsedMilliseconds: Double) {
        presentedCount += 1
        lastPresentMilliseconds = elapsedMilliseconds
        publishFrameStatus()
        onDiagnostic?(
            String(
                format: "frame present#%d apply#%d completed=%.3fms",
                presentedCount,
                frame,
                elapsedMilliseconds
            )
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        onDiagnostic?(String(format: "Metal drawable %.0f×%.0f", size.width, size.height))
    }

    func draw(in view: MTKView) {
        guard let desktopTexture,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let content = aspectFitRectangle(
            in: CGRect(origin: .zero, size: drawableSize),
            contentSize: remoteDesktopSize
        )
        encoder.setViewport(MTLViewport(
            originX: content.minX,
            originY: content.minY,
            width: content.width,
            height: content.height,
            znear: 0,
            zfar: 1
        ))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(desktopTexture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        let submittedAt = CACurrentMediaTime()
        let frame = applyCount
#if targetEnvironment(simulator)
        // Xcode 26's Simulator Metal SDK omits MTLDrawable's presented
        // handler. Keep the fixture build/testable there and label the
        // completion as a GPU completion proxy; device runs retain the real
        // presentation callback below.
        commandBuffer.addCompletedHandler { [weak self] _ in
            let elapsedMilliseconds = (CACurrentMediaTime() - submittedAt) * 1_000
            Task { @MainActor [weak self] in
                self?.recordPresentation(
                    frame: frame,
                    elapsedMilliseconds: elapsedMilliseconds
                )
            }
        }
#else
        drawable.addPresentedHandler { [weak self] _ in
            let elapsedMilliseconds = (CACurrentMediaTime() - submittedAt) * 1_000
            Task { @MainActor [weak self] in
                self?.recordPresentation(
                    frame: frame,
                    elapsedMilliseconds: elapsedMilliseconds
                )
            }
        }
#endif
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastSubmittedCommandBuffer = commandBuffer
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}
