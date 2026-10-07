import Foundation

public struct ViewportPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = ViewportPoint(x: 0, y: 0)
}

public struct ViewportSize: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }
    public static let zero = ViewportSize(width: 0, height: 0)
}

public struct ViewportRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public static let zero = ViewportRect(x: 0, y: 0, width: 0, height: 0)
}

/// The single place local and remote coordinates are related.
///
/// docs/architecture.md section 6 requires one transform behind hover, click,
/// drag and touch alike. Two separate mappings would drift the moment the
/// device rotates or the user zooms, and the symptom - a pointer that lands
/// somewhere other than where it was released - is very hard to attribute
/// back to whichever path was not updated.
public struct ViewportTransform: Hashable, Sendable {
    public let desktopWidth: Int
    public let desktopHeight: Int
    public let viewport: ViewportSize
    public let scaleMode: InitialScale
    /// User zoom on top of the scale mode. 1.0 is the mode's own scale.
    public let zoom: Double
    /// Pan in viewport points, already clamped so the desktop cannot be
    /// dragged off screen.
    public let pan: ViewportPoint

    public static let minimumZoom = 1.0
    public static let maximumZoom = 8.0

    public init(
        desktopWidth: Int,
        desktopHeight: Int,
        viewport: ViewportSize,
        scaleMode: InitialScale = .fit,
        zoom: Double = 1.0,
        pan: ViewportPoint = .zero
    ) {
        let clampedZoom = Self.clampZoom(zoom)
        self.desktopWidth = desktopWidth
        self.desktopHeight = desktopHeight
        self.viewport = viewport
        self.scaleMode = scaleMode
        self.zoom = clampedZoom
        // Pan is stored already clamped so that no consumer can observe an
        // offset that would show the ground behind the desktop.
        self.pan = Self.clampPan(
            pan,
            limits: Self.panLimits(
                desktopWidth: desktopWidth,
                desktopHeight: desktopHeight,
                viewport: viewport,
                scale: Self.baseScale(
                    desktopWidth: desktopWidth,
                    desktopHeight: desktopHeight,
                    viewport: viewport,
                    scaleMode: scaleMode
                ) * clampedZoom
            )
        )
    }

    public static func clampZoom(_ zoom: Double) -> Double {
        guard zoom.isFinite else { return minimumZoom }
        return min(max(zoom, minimumZoom), maximumZoom)
    }

    /// Viewport points per desktop pixel, before user zoom.
    public var baseScale: Double {
        Self.baseScale(
            desktopWidth: desktopWidth,
            desktopHeight: desktopHeight,
            viewport: viewport,
            scaleMode: scaleMode
        )
    }

    private static func baseScale(
        desktopWidth: Int,
        desktopHeight: Int,
        viewport: ViewportSize,
        scaleMode: InitialScale
    ) -> Double {
        guard desktopWidth > 0, desktopHeight > 0, !viewport.isEmpty else { return 1 }
        switch scaleMode {
        case .fit:
            return min(
                viewport.width / Double(desktopWidth),
                viewport.height / Double(desktopHeight)
            )
        case .oneToOne:
            return 1
        }
    }

    public var scale: Double { baseScale * zoom }

    /// Where the desktop is drawn inside the viewport: centred, then panned.
    /// A desktop narrower than the screen does not sit in a corner, and one
    /// zoomed past it grows from the middle and pans as far as each edge.
    public var contentRect: ViewportRect {
        guard desktopWidth > 0, desktopHeight > 0, !viewport.isEmpty else { return .zero }
        let scale = scale
        let width = Double(desktopWidth) * scale
        let height = Double(desktopHeight) * scale
        return ViewportRect(
            x: (viewport.width - width) / 2 + pan.x,
            y: (viewport.height - height) / 2 + pan.y,
            width: width,
            height: height
        )
    }

    /// How far the content may be dragged on each axis. Zero on an axis that
    /// already fits, which is what stops a fitted desktop from being flicked
    /// out of view.
    public var panLimits: (x: Double, y: Double) {
        Self.panLimits(
            desktopWidth: desktopWidth,
            desktopHeight: desktopHeight,
            viewport: viewport,
            scale: scale
        )
    }

    public func clampedPan(_ candidate: ViewportPoint) -> ViewportPoint {
        Self.clampPan(candidate, limits: panLimits)
    }

    private static func panLimits(
        desktopWidth: Int,
        desktopHeight: Int,
        viewport: ViewportSize,
        scale: Double
    ) -> (x: Double, y: Double) {
        let width = Double(desktopWidth) * scale
        let height = Double(desktopHeight) * scale
        return (
            x: max(width - viewport.width, 0) / 2,
            y: max(height - viewport.height, 0) / 2
        )
    }

    private static func clampPan(
        _ candidate: ViewportPoint,
        limits: (x: Double, y: Double)
    ) -> ViewportPoint {
        let x = candidate.x.isFinite ? min(max(candidate.x, -limits.x), limits.x) : 0
        let y = candidate.y.isFinite ? min(max(candidate.y, -limits.y), limits.y) : 0
        return ViewportPoint(x: x, y: y)
    }

    public func with(
        viewport: ViewportSize? = nil,
        scaleMode: InitialScale? = nil,
        zoom: Double? = nil,
        pan: ViewportPoint? = nil
    ) -> ViewportTransform {
        ViewportTransform(
            desktopWidth: desktopWidth,
            desktopHeight: desktopHeight,
            viewport: viewport ?? self.viewport,
            scaleMode: scaleMode ?? self.scaleMode,
            zoom: zoom ?? self.zoom,
            pan: pan ?? self.pan
        )
    }

    public func with(desktopWidth: Int, desktopHeight: Int) -> ViewportTransform {
        // A resolution change invalidates the pan: the old offset was measured
        // against a surface that no longer exists.
        ViewportTransform(
            desktopWidth: desktopWidth,
            desktopHeight: desktopHeight,
            viewport: viewport,
            scaleMode: scaleMode,
            zoom: zoom,
            pan: .zero
        )
    }

    /// Maps a point in the viewport onto a remote desktop pixel, clamped to
    /// the desktop. A press that begins inside the content and drags past its
    /// edge keeps sending the edge pixel rather than nothing, which is what
    /// makes a drag-to-select gesture behave.
    public func remotePixel(fromLocal point: ViewportPoint) -> PixelPoint {
        let content = contentRect
        guard content.width > 0, content.height > 0,
              desktopWidth > 0, desktopHeight > 0 else {
            return PixelPoint(x: 0, y: 0)
        }
        let normalizedX = (point.x - content.x) / content.width
        let normalizedY = (point.y - content.y) / content.height
        return PixelPoint(
            x: Self.clampPixel(normalizedX * Double(desktopWidth), limit: desktopWidth),
            y: Self.clampPixel(normalizedY * Double(desktopHeight), limit: desktopHeight)
        )
    }

    /// The inverse, for drawing a remote cursor at the right place locally.
    public func localPoint(fromRemote pixel: PixelPoint) -> ViewportPoint {
        let content = contentRect
        guard desktopWidth > 0, desktopHeight > 0 else { return .zero }
        return ViewportPoint(
            x: content.x + (Double(pixel.x) + 0.5) / Double(desktopWidth) * content.width,
            y: content.y + (Double(pixel.y) + 0.5) / Double(desktopHeight) * content.height
        )
    }

    private static func clampPixel(_ value: Double, limit: Int) -> Int {
        guard value.isFinite else { return 0 }
        let floored = value.rounded(.down)
        guard floored > 0 else { return 0 }
        guard floored < Double(limit - 1) else { return limit - 1 }
        return Int(floored)
    }
}

public struct PixelPoint: Hashable, Sendable {
    public var x: Int
    public var y: Int

    public init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}
