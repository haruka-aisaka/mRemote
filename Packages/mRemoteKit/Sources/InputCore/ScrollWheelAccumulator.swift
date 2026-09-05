import Foundation
import SessionCore

public struct QuantizedScrollDelta: Hashable, Sendable {
    public let horizontal: Int32
    public let vertical: Int32

    public init(horizontal: Int32, vertical: Int32) {
        self.horizontal = horizontal
        self.vertical = vertical
    }

    public var isZero: Bool { horizontal == 0 && vertical == 0 }
}

/// Turns continuous device scrolling into the integer rotation units RDP
/// carries.
///
/// Two conversions happen here and both matter. RDP measures a wheel in units
/// of 120 per detent, while iPadOS reports a trackpad scroll as a stream of
/// points, so a point has to be scaled or a page scroll would take a hundred
/// gestures. And a scaled point is rarely a whole unit, so the remainder is
/// kept per axis until it becomes one - dropping it would make slow scrolling
/// do nothing at all rather than move slowly.
public struct ScrollWheelAccumulator: Sendable {
    /// Rotation units per point of device scrolling. RDP defines 120 units as
    /// one detent and iPadOS reports roughly ten points per detent of trackpad
    /// scrolling, so a point is about twelve units. It is a constant rather
    /// than a setting because the thing a user would want to tune is scroll
    /// speed, which Windows already owns.
    public static let unitsPerPoint = 12.0

    public private(set) var direction: ScrollDirection
    private var horizontalResidual = 0.0
    private var verticalResidual = 0.0

    public init(direction: ScrollDirection = .normal) {
        self.direction = direction
    }

    /// `horizontal` and `vertical` are device points. Positive vertical means
    /// the fingers moved down the trackpad, which scrolls the content up, and
    /// which RDP encodes as a positive rotation.
    public mutating func consume(horizontal: Double, vertical: Double) -> QuantizedScrollDelta {
        let multiplier = (direction == .reversed ? -1.0 : 1.0) * Self.unitsPerPoint
        return QuantizedScrollDelta(
            horizontal: Self.consumeAxis(horizontal * multiplier, residual: &horizontalResidual),
            vertical: Self.consumeAxis(vertical * multiplier, residual: &verticalResidual)
        )
    }

    /// A direction change must not reinterpret a fraction that accumulated
    /// under the previous setting, so the remainder is dropped rather than
    /// negated.
    @discardableResult
    public mutating func setDirection(_ newDirection: ScrollDirection) -> Bool {
        guard newDirection != direction else { return false }
        reset()
        direction = newDirection
        return true
    }

    public mutating func reset() {
        horizontalResidual = 0
        verticalResidual = 0
    }

    private static func consumeAxis(_ delta: Double, residual: inout Double) -> Int32 {
        guard delta.isFinite else { return 0 }

        let total = residual + delta
        guard total.isFinite else {
            // An overflowing synthetic input must not poison every later event
            // with an infinite remainder.
            residual = 0
            return total.sign == .minus ? Int32.min : Int32.max
        }

        // Toward zero is symmetric: a negative fraction must not produce an
        // event one step earlier than the matching positive one.
        let wholeUnits = total.rounded(.towardZero)
        guard wholeUnits >= Double(Int32.min), wholeUnits <= Double(Int32.max) else {
            residual = 0
            return wholeUnits.sign == .minus ? Int32.min : Int32.max
        }
        residual = total - wholeUnits
        return Int32(wholeUnits)
    }
}
