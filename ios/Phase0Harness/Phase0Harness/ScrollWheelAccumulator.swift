enum ScrollDirection: String, Equatable, Sendable {
    case normal
    case reversed
}

struct QuantizedScrollDelta: Equatable, Sendable {
    let horizontal: Int32
    let vertical: Int32

    var isZero: Bool {
        horizontal == 0 && vertical == 0
    }
}

/// Converts continuous device deltas to the signed integer units accepted by
/// the native bridge. Horizontal and vertical fractions are retained
/// independently until they reach a whole unit.
struct ScrollWheelAccumulator: Sendable {
    private(set) var direction: ScrollDirection
    private var horizontalResidual = 0.0
    private var verticalResidual = 0.0

    init(direction: ScrollDirection = .normal) {
        self.direction = direction
    }

    mutating func consume(horizontal: Double, vertical: Double) -> QuantizedScrollDelta {
        let multiplier = direction == .reversed ? -1.0 : 1.0
        return QuantizedScrollDelta(
            horizontal: Self.consumeAxis(
                horizontal * multiplier,
                residual: &horizontalResidual
            ),
            vertical: Self.consumeAxis(
                vertical * multiplier,
                residual: &verticalResidual
            )
        )
    }

    /// A direction boundary must not reinterpret a fraction accumulated under
    /// the previous setting.
    @discardableResult
    mutating func setDirection(_ newDirection: ScrollDirection) -> Bool {
        guard newDirection != direction else { return false }
        reset()
        direction = newDirection
        return true
    }

    mutating func reset() {
        horizontalResidual = 0
        verticalResidual = 0
    }

    private static func consumeAxis(_ delta: Double, residual: inout Double) -> Int32 {
        guard delta.isFinite else { return 0 }

        let total = residual + delta
        guard total.isFinite else {
            // An overflowing synthetic input must not permanently poison later
            // input with an infinite residual.
            residual = 0
            return total.sign == .minus ? Int32.min : Int32.max
        }

        // Toward-zero extraction is symmetric: a negative fraction does not
        // become a -1 event earlier than the matching positive fraction.
        let wholeUnits = total.rounded(.towardZero)
        guard wholeUnits >= Double(Int32.min),
              wholeUnits <= Double(Int32.max) else {
            // Saturate one malformed/extreme event, but do not retain a huge
            // residual that would drown out all subsequent device input.
            residual = 0
            return wholeUnits.sign == .minus ? Int32.min : Int32.max
        }
        residual = total - wholeUnits
        return Int32(wholeUnits)
    }
}
