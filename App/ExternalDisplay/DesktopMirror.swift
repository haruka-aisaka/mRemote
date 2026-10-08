import MetalKit
import SwiftUI
import UIKit

/// The desktop as the session's own surface holds it, for a second screen
/// to draw: the texture the surface uploads frames into, the part of it to
/// show, and where the remote pointer is.
///
/// The surface stays the one place frames are consumed and input is sent;
/// a mirror only reads. Owned by the session's model, so it outlives the
/// views on either side.
@MainActor
final class DesktopMirror {
    private(set) var texture: MTLTexture?
    /// The part of the desktop, in pixels, this mirror shows. Nil for all
    /// of it.
    var sourceRect: CGRect? {
        didSet { if sourceRect != oldValue { changed() } }
    }
    private(set) var cursorPixel: CGPoint?
    private(set) var cursorImage: CGImage?
    /// The hotspot and size in desktop pixels; zero for the fallback arrow,
    /// which is drawn at a fixed size on the mirror's screen.
    private(set) var cursorHotspot = CGPoint.zero
    private(set) var cursorPixelSize = CGSize.zero

    /// Desktop pixels per point of the mirror's view, as last drawn: what a
    /// trackpad moving a pointer nobody sees on the device goes by.
    var pixelsPerPoint: Double?

    private var views = NSHashTable<DesktopMirrorView>.weakObjects()
    /// Command buffers a mirror view submitted and that may still be reading
    /// the texture; the surface waits for them before it writes.
    private var pendingReads: [MTLCommandBuffer] = []

    var hasViews: Bool { views.count > 0 }

    func attach(_ view: DesktopMirrorView) {
        views.add(view)
        view.setNeedsDisplay()
    }

    func detach(_ view: DesktopMirrorView) {
        views.remove(view)
    }

    func publish(texture: MTLTexture?) {
        self.texture = texture
        changed()
    }

    func publishCursor(pixel: CGPoint?, image: CGImage?, hotspot: CGPoint, pixelSize: CGSize) {
        cursorPixel = pixel
        cursorImage = image
        cursorHotspot = hotspot
        cursorPixelSize = pixelSize
        for view in views.allObjects {
            view.positionCursor()
        }
    }

    func didSubmitRead(_ commandBuffer: MTLCommandBuffer) {
        pendingReads.removeAll { $0.status == .completed || $0.status == .error }
        pendingReads.append(commandBuffer)
    }

    /// Before a CPU write into the shared texture.
    func waitForReads() {
        for commandBuffer in pendingReads where commandBuffer.status != .completed && commandBuffer.status != .error {
            commandBuffer.waitUntilCompleted()
        }
        pendingReads.removeAll()
    }

    private func changed() {
        for view in views.allObjects {
            view.setNeedsDisplay()
            view.positionCursor()
        }
    }
}

/// Draws a `DesktopMirror` fitted into its bounds, with the remote pointer.
/// Display only: it takes no touches and no keys.
final class DesktopMirrorView: MTKView, MTKViewDelegate {
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct RasterizerData {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    // rect is (left, top, right, bottom) in normalised device coordinates;
    // source is (left, top, right, bottom) in texture coordinates.
    vertex RasterizerData mirrorVertex(
        uint vertexID [[vertex_id]],
        constant float4 &rect [[buffer(0)]],
        constant float4 &source [[buffer(1)]]) {
        const float2 corners[] = {
            float2(0.0, 0.0), float2(1.0, 0.0),
            float2(0.0, 1.0), float2(1.0, 1.0)
        };
        float2 corner = corners[vertexID];
        RasterizerData output;
        output.position = float4(mix(rect.x, rect.z, corner.x), mix(rect.y, rect.w, corner.y), 0.0, 1.0);
        output.textureCoordinate = float2(mix(source.x, source.z, corner.x), mix(source.y, source.w, corner.y));
        return output;
    }

    fragment float4 mirrorFragment(
        RasterizerData input [[stage_in]],
        texture2d<float> desktop [[texture(0)]]) {
        constexpr sampler desktopSampler(mag_filter::nearest, min_filter::linear);
        return desktop.sample(desktopSampler, input.textureCoordinate);
    }
    """

    let mirror: DesktopMirror
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let cursorLayer = CALayer()

    @MainActor
    init(mirror: DesktopMirror) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil) else {
            fatalError("Metal is required to present a remote desktop")
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "mirrorVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "mirrorFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            fatalError("Could not create the desktop mirror pipeline")
        }
        self.mirror = mirror
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        super.init(frame: .zero, device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = true
        delegate = self
        isOpaque = true
        isUserInteractionEnabled = false
        accessibilityIdentifier = "desktop-mirror"
        cursorLayer.isHidden = true
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.zPosition = 1
        layer.addSublayer(cursorLayer)
        mirror.attach(self)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// The part of the texture shown, in pixels.
    @MainActor
    private var source: CGRect? {
        guard let texture = mirror.texture else { return nil }
        let whole = CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        return mirror.sourceRect?.intersection(whole) ?? whole
    }

    /// The source fitted into the bounds, centred, in points.
    @MainActor
    private func contentRect(for source: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let size = CGSize(width: source.width * scale, height: source.height * scale)
        return CGRect(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
        MainActor.assumeIsolated { positionCursor() }
    }

    @MainActor
    func positionCursor() {
        guard let source, let pixel = mirror.cursorPixel, source.contains(pixel) else {
            cursorLayer.isHidden = true
            return
        }
        let content = contentRect(for: source)
        let scale = content.width / source.width
        let location = CGPoint(
            x: content.minX + (pixel.x - source.minX) * scale,
            y: content.minY + (pixel.y - source.minY) * scale
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let image = mirror.cursorImage, mirror.cursorPixelSize != .zero {
            cursorLayer.contents = image
            cursorLayer.frame = CGRect(
                x: location.x - mirror.cursorHotspot.x * scale,
                y: location.y - mirror.cursorHotspot.y * scale,
                width: mirror.cursorPixelSize.width * scale,
                height: mirror.cursorPixelSize.height * scale
            )
        } else {
            cursorLayer.contents = mirror.cursorImage
            cursorLayer.frame = CGRect(origin: location, size: CGSize(width: 13, height: 20))
        }
        cursorLayer.isHidden = cursorLayer.contents == nil
        CATransaction.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        MainActor.assumeIsolated {
            guard let texture = mirror.texture, let source,
                  let descriptor = currentRenderPassDescriptor,
                  let drawable = currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            let content = contentRect(for: source)
            mirror.pixelsPerPoint = Double(source.width / max(content.width, 1))
            let width = max(bounds.width, 1)
            let height = max(bounds.height, 1)
            var rect = SIMD4<Float>(
                Float(2 * content.minX / width - 1),
                Float(1 - 2 * content.minY / height),
                Float(2 * content.maxX / width - 1),
                Float(1 - 2 * content.maxY / height)
            )
            var sourceCoordinates = SIMD4<Float>(
                Float(source.minX / CGFloat(texture.width)),
                Float(source.minY / CGFloat(texture.height)),
                Float(source.maxX / CGFloat(texture.width)),
                Float(source.maxY / CGFloat(texture.height))
            )
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setVertexBytes(&sourceCoordinates, length: MemoryLayout<SIMD4<Float>>.size, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            mirror.didSubmitRead(commandBuffer)
        }
    }
}

struct DesktopMirrorSurface: UIViewRepresentable {
    let mirror: DesktopMirror

    func makeUIView(context: Context) -> DesktopMirrorView {
        DesktopMirrorView(mirror: mirror)
    }

    func updateUIView(_ view: DesktopMirrorView, context: Context) {
        view.setNeedsDisplay()
    }
}
