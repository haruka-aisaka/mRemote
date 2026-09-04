import CoreGraphics
import Foundation

enum BGRADesktopUpdateError: Error, Equatable, CustomStringConvertible {
    case invalidDimensions
    case invalidStride
    case arithmeticOverflow
    case truncatedBuffer(required: Int, actual: Int)
    case invalidDirtyRectangle(CGRect)
    case metalTextureAllocationFailed

    var description: String {
        switch self {
        case .invalidDimensions: return "desktop dimensions must be positive"
        case .invalidStride: return "BGRA stride is smaller than width * 4"
        case .arithmeticOverflow: return "BGRA dimensions overflow addressable memory"
        case let .truncatedBuffer(required, actual):
            return "BGRA buffer truncated required=\(required) actual=\(actual)"
        case let .invalidDirtyRectangle(rect): return "dirty rectangle out of bounds: \(rect)"
        case .metalTextureAllocationFailed: return "Metal texture allocation failed"
        }
    }
}

struct ValidatedPixelRectangle: Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct ValidatedBGRADesktopUpdate: Equatable {
    let requiredBytes: Int
    let fullDesktopRectangle: ValidatedPixelRectangle
    let rectangles: [ValidatedPixelRectangle]

    func rectanglesForTexture(requiresFullSeed: Bool) -> [ValidatedPixelRectangle] {
        requiresFullSeed ? [fullDesktopRectangle] : rectangles
    }
}

/// Pixel damage associated with a full-frame snapshot waiting in a latest-only
/// mailbox. An empty rectangle list means the whole surface is dirty, matching
/// `BGRADesktopUpdateValidator` semantics.
struct FrameDamageEnvelope: Equatable {
    let generation: UInt64
    let surfaceGeneration: UInt64
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let dirtyRectangles: [CGRect]
}

enum LatestFrameDamageCoalescer {
    static func coalescedDamage(
        replacing pending: FrameDamageEnvelope,
        with newest: FrameDamageEnvelope
    ) -> [CGRect] {
        guard pending.generation == newest.generation,
              pending.surfaceGeneration == newest.surfaceGeneration,
              pending.width == newest.width,
              pending.height == newest.height,
              pending.bytesPerRow == newest.bytesPerRow else {
            return []
        }
        guard let pendingDamage = boundingRectangle(pending.dirtyRectangles),
              let newestDamage = boundingRectangle(newest.dirtyRectangles) else {
            return []
        }

        let combined = pendingDamage.union(newestDamage)
        let fullSurface = CGRect(x: 0, y: 0, width: newest.width, height: newest.height)
        return combined == fullSurface ? [] : [combined]
    }

    private static func boundingRectangle(_ rectangles: [CGRect]) -> CGRect? {
        guard var result = rectangles.first else { return nil }
        for rectangle in rectangles.dropFirst() {
            result = result.union(rectangle)
        }
        return result
    }
}

enum BGRADesktopUpdateValidator {
    static func validate(
        width: Int,
        height: Int,
        bytesPerRow: Int,
        pixelCount: Int,
        dirtyRectangles: [CGRect]
    ) throws -> ValidatedBGRADesktopUpdate {
        guard width > 0, height > 0 else {
            throw BGRADesktopUpdateError.invalidDimensions
        }

        let (minimumBytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        guard !rowOverflow else {
            throw BGRADesktopUpdateError.arithmeticOverflow
        }
        guard bytesPerRow >= minimumBytesPerRow else {
            throw BGRADesktopUpdateError.invalidStride
        }

        let (requiredBytes, bufferOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !bufferOverflow else {
            throw BGRADesktopUpdateError.arithmeticOverflow
        }
        guard pixelCount >= requiredBytes else {
            throw BGRADesktopUpdateError.truncatedBuffer(
                required: requiredBytes,
                actual: pixelCount
            )
        }

        let fullDesktopRectangle = ValidatedPixelRectangle(
            x: 0,
            y: 0,
            width: width,
            height: height
        )
        let rectangles: [ValidatedPixelRectangle]
        if dirtyRectangles.isEmpty {
            rectangles = [fullDesktopRectangle]
        } else {
            rectangles = try dirtyRectangles.map {
                try validateRectangle($0, desktopWidth: width, desktopHeight: height)
            }
        }
        return ValidatedBGRADesktopUpdate(
            requiredBytes: requiredBytes,
            fullDesktopRectangle: fullDesktopRectangle,
            rectangles: rectangles
        )
    }

    private static func validateRectangle(
        _ rectangle: CGRect,
        desktopWidth: Int,
        desktopHeight: Int
    ) throws -> ValidatedPixelRectangle {
        guard rectangle.origin.x.isFinite, rectangle.origin.y.isFinite,
              rectangle.width.isFinite, rectangle.height.isFinite,
              rectangle.width > 0, rectangle.height > 0 else {
            throw BGRADesktopUpdateError.invalidDirtyRectangle(rectangle)
        }

        // Convert only after checking all rounded values. Int(CGFloat) traps
        // for finite-but-out-of-range inputs, which native callback data must
        // never be able to trigger.
        let minX = floor(rectangle.minX)
        let minY = floor(rectangle.minY)
        let maxX = ceil(rectangle.maxX)
        let maxY = ceil(rectangle.maxY)
        guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite,
              minX >= 0, minY >= 0,
              maxX > minX, maxY > minY,
              maxX <= CGFloat(desktopWidth), maxY <= CGFloat(desktopHeight),
              let x = Int(exactly: minX), let y = Int(exactly: minY),
              let right = Int(exactly: maxX), let bottom = Int(exactly: maxY) else {
            throw BGRADesktopUpdateError.invalidDirtyRectangle(rectangle)
        }

        return ValidatedPixelRectangle(
            x: x,
            y: y,
            width: right - x,
            height: bottom - y
        )
    }
}
