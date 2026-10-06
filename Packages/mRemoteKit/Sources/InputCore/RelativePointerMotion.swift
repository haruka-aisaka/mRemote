import Foundation
import SessionCore

/// Moves the remote pointer by finger travel on an on-screen trackpad.
///
/// The surface's own pointer is absolute - the remote pointer goes where the
/// local one is - but a trackpad drawn on the other half of a folded screen
/// has no point in common with the desktop, so it moves the pointer the way a
/// laptop trackpad does: by how far and how fast the finger went.
///
/// The fraction of a pixel left over by each step is kept, so slow, careful
/// movement still arrives instead of being rounded away event by event.
public struct RelativePointerMotion: Sendable {
    /// Below this speed in points per second travel is one to one with what
    /// the desktop is drawn at; above it the gain ramps up to `maximumGain`.
    public static let accelerationThreshold = 150.0
    public static let accelerationRange = 900.0
    public static let maximumGain = 3.0

    private var remainderX = 0.0
    private var remainderY = 0.0

    public init() {}

    public static func gain(forSpeed speed: Double) -> Double {
        guard speed.isFinite, speed > accelerationThreshold else { return 1 }
        let ramp = min((speed - accelerationThreshold) / accelerationRange, 1)
        return 1 + (maximumGain - 1) * ramp
    }

    /// - Parameters:
    ///   - pixelsPerPoint: desktop pixels per point of finger travel at gain
    ///     1. The surface passes the inverse of its drawing scale, so a
    ///     finger moved one point moves the pointer one point across the
    ///     picture of the desktop.
    ///   - speed: finger speed in points per second.
    public mutating func next(
        from pixel: PixelPoint,
        dx: Double,
        dy: Double,
        pixelsPerPoint: Double,
        speed: Double,
        desktopWidth: Int,
        desktopHeight: Int
    ) -> PixelPoint {
        guard desktopWidth > 0, desktopHeight > 0,
              dx.isFinite, dy.isFinite, pixelsPerPoint.isFinite, pixelsPerPoint > 0 else {
            return pixel
        }
        let gain = Self.gain(forSpeed: speed) * pixelsPerPoint
        let exactX = Double(pixel.x) + remainderX + dx * gain
        let exactY = Double(pixel.y) + remainderY + dy * gain
        let x = Self.clamp(exactX.rounded(.towardZero), limit: desktopWidth)
        let y = Self.clamp(exactY.rounded(.towardZero), limit: desktopHeight)
        // Pushing against an edge must not bank travel that would have to be
        // undone before the pointer comes back off it.
        remainderX = Double(x) == exactX.rounded(.towardZero) ? exactX - Double(x) : 0
        remainderY = Double(y) == exactY.rounded(.towardZero) ? exactY - Double(y) : 0
        return PixelPoint(x: x, y: y)
    }

    public mutating func reset() {
        remainderX = 0
        remainderY = 0
    }

    private static func clamp(_ value: Double, limit: Int) -> Int {
        Int(min(max(value, 0), Double(limit - 1)))
    }
}
