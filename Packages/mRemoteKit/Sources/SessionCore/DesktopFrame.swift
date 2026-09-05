import Foundation

/// A rectangle in remote desktop pixels. Deliberately integral: every value
/// here originates in a native callback, and a floating-point rectangle would
/// only reintroduce the rounding question at the texture upload.
public struct PixelRect: Hashable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Int { x + width }
    public var maxY: Int { y + height }
    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public func union(_ other: PixelRect) -> PixelRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let minX = Swift.min(x, other.x)
        let minY = Swift.min(y, other.y)
        return PixelRect(
            x: minX,
            y: minY,
            width: Swift.max(maxX, other.maxX) - minX,
            height: Swift.max(maxY, other.maxY) - minY
        )
    }
}

/// One BGRA8 surface already copied out of the protocol layer.
///
/// An empty `dirtyRectangles` means the whole surface is damaged. That is the
/// only encoding of "everything changed": a renderer that cannot tell which
/// region moved must upload all of it rather than guess, and coalescing two
/// frames whose geometry differs produces exactly this.
public struct DesktopFrame: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixels: Data
    public let dirtyRectangles: [PixelRect]
    /// The connection attempt this surface belongs to. A frame carrying an
    /// older generation belongs to a connection that has already ended.
    public let generation: SessionGeneration
    /// Increments whenever the remote desktop is reallocated, e.g. after a
    /// resolution change. Two frames with different surface generations can
    /// never have their damage combined.
    public let surfaceGeneration: UInt64
    public let frameID: UInt64

    public init(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixels: Data,
        dirtyRectangles: [PixelRect],
        generation: SessionGeneration,
        surfaceGeneration: UInt64,
        frameID: UInt64
    ) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
        self.dirtyRectangles = dirtyRectangles
        self.generation = generation
        self.surfaceGeneration = surfaceGeneration
        self.frameID = frameID
    }

    public var desktopRectangle: PixelRect {
        PixelRect(x: 0, y: 0, width: width, height: height)
    }

    /// True when the two frames describe the same surface, so their damage may
    /// be combined instead of escalated to a full upload.
    public func describesSameSurface(as other: DesktopFrame) -> Bool {
        generation == other.generation
            && surfaceGeneration == other.surfaceGeneration
            && width == other.width
            && height == other.height
            && bytesPerRow == other.bytesPerRow
    }

    /// Replaces this frame's damage. Used when a newer frame supersedes one
    /// the renderer never drew: the pixels are the newer ones, but the damage
    /// has to cover what the renderer still owes from the older frame.
    public func withDamage(_ dirtyRectangles: [PixelRect]) -> DesktopFrame {
        DesktopFrame(
            width: width,
            height: height,
            bytesPerRow: bytesPerRow,
            pixels: pixels,
            dirtyRectangles: dirtyRectangles,
            generation: generation,
            surfaceGeneration: surfaceGeneration,
            frameID: frameID
        )
    }
}

public enum DesktopFrameError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalidDimensions(width: Int, height: Int)
    case invalidStride(bytesPerRow: Int, minimum: Int)
    case arithmeticOverflow
    case bufferTooLarge(required: Int, limit: Int)
    case truncatedBuffer(required: Int, actual: Int)
    case invalidDirtyRectangle(PixelRect)
    case tooManyDirtyRectangles(count: Int, limit: Int)

    public var description: String {
        switch self {
        case let .invalidDimensions(width, height):
            return "desktop dimensions must be positive: \(width)x\(height)"
        case let .invalidStride(bytesPerRow, minimum):
            return "BGRA stride \(bytesPerRow) is smaller than \(minimum)"
        case .arithmeticOverflow:
            return "BGRA dimensions overflow addressable memory"
        case let .bufferTooLarge(required, limit):
            return "BGRA buffer \(required) exceeds the \(limit) byte limit"
        case let .truncatedBuffer(required, actual):
            return "BGRA buffer truncated required=\(required) actual=\(actual)"
        case let .invalidDirtyRectangle(rect):
            return "dirty rectangle out of bounds: \(rect)"
        case let .tooManyDirtyRectangles(count, limit):
            return "dirty rectangle count \(count) exceeds \(limit)"
        }
    }
}

public struct ValidatedDesktopFrame: Hashable, Sendable {
    public let requiredBytes: Int
    public let desktopRectangle: PixelRect
    public let rectangles: [PixelRect]

    /// A newly allocated texture holds undefined pixels, so the first upload
    /// after an allocation has to cover the whole surface even when the frame
    /// only claims a small region changed.
    public func rectanglesForUpload(requiresFullSeed: Bool) -> [PixelRect] {
        requiresFullSeed ? [desktopRectangle] : rectangles
    }
}

/// Bounds-checks a frame before anything indexes into its bytes.
///
/// The limits mirror the C bridge header rather than being chosen here, so a
/// value the bridge would have refused is refused again on this side: the two
/// checks are independent, and neither is allowed to be the only one.
public enum DesktopFrameValidator {
    public static let maximumDimension = 8_192
    public static let maximumFrameBytes = 512 * 1_024 * 1_024
    public static let maximumDirtyRectangles = 512

    public static func validate(_ frame: DesktopFrame) throws -> ValidatedDesktopFrame {
        try validate(
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            byteCount: frame.pixels.count,
            dirtyRectangles: frame.dirtyRectangles
        )
    }

    public static func validate(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        byteCount: Int,
        dirtyRectangles: [PixelRect]
    ) throws -> ValidatedDesktopFrame {
        guard width > 0, height > 0,
              width <= maximumDimension, height <= maximumDimension else {
            throw DesktopFrameError.invalidDimensions(width: width, height: height)
        }
        let (minimumBytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else { throw DesktopFrameError.arithmeticOverflow }
        guard bytesPerRow >= minimumBytesPerRow else {
            throw DesktopFrameError.invalidStride(
                bytesPerRow: bytesPerRow,
                minimum: minimumBytesPerRow
            )
        }
        let (requiredBytes, bufferOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !bufferOverflow else { throw DesktopFrameError.arithmeticOverflow }
        guard requiredBytes <= maximumFrameBytes else {
            throw DesktopFrameError.bufferTooLarge(
                required: requiredBytes,
                limit: maximumFrameBytes
            )
        }
        guard byteCount >= requiredBytes else {
            throw DesktopFrameError.truncatedBuffer(
                required: requiredBytes,
                actual: byteCount
            )
        }
        guard dirtyRectangles.count <= maximumDirtyRectangles else {
            throw DesktopFrameError.tooManyDirtyRectangles(
                count: dirtyRectangles.count,
                limit: maximumDirtyRectangles
            )
        }

        let desktopRectangle = PixelRect(x: 0, y: 0, width: width, height: height)
        let rectangles: [PixelRect]
        if dirtyRectangles.isEmpty {
            rectangles = [desktopRectangle]
        } else {
            rectangles = try dirtyRectangles.map { rectangle in
                guard rectangle.width > 0, rectangle.height > 0,
                      rectangle.x >= 0, rectangle.y >= 0,
                      rectangle.maxX > rectangle.x, rectangle.maxY > rectangle.y,
                      rectangle.maxX <= width, rectangle.maxY <= height else {
                    throw DesktopFrameError.invalidDirtyRectangle(rectangle)
                }
                return rectangle
            }
        }
        return ValidatedDesktopFrame(
            requiredBytes: requiredBytes,
            desktopRectangle: desktopRectangle,
            rectangles: rectangles
        )
    }
}
