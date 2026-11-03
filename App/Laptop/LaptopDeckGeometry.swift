import CoreGraphics

/// Where the keys, the trackpad and its buttons go in the deck.
///
/// The keyboard keeps one shape - square keys, as on a physical keyboard -
/// whatever the deck's: keys squashed flat cannot be typed on, so the pad
/// takes whatever height is left, and goes when what is left is too little
/// to move a pointer with. Kept apart from the view so the rules can be
/// tested without one.
struct LaptopDeckGeometry: Equatable {
    /// The keyboard drawn whole, or nil when it is split or hidden.
    var keyboard: CGRect?
    /// The two halves of a split keyboard.
    var leftHalf: CGRect?
    var rightHalf: CGRect?
    var pad: CGRect?
    var leftButton: CGRect?
    var rightButton: CGRect?

    var showsPad: Bool { pad != nil }

    /// The keyboard's rows, in the units `LaptopKeyboardRow.height` uses.
    struct Rows: Equatable {
        var heights: [Double]
        /// How many key widths one row (or one half) spans.
        var units: Double

        var totalHeight: Double { heights.reduce(0, +) }

        /// The height of the keys `width` wide, with each key square.
        ///
        /// A key's pitch is `unit` both ways: its cap is inset by the gap
        /// across (`LaptopDeckView.layoutRows`), and the rows are a gap
        /// apart, so a cap `unit - gap` tall is square.
        func height(forWidth width: CGFloat) -> CGFloat {
            let unit = width / CGFloat(units)
            let gaps = LaptopDeckGeometry.rowGap * CGFloat(max(heights.count - 1, 0))
            return max(unit - LaptopDeckGeometry.rowGap, 0) * CGFloat(totalHeight) + gaps
        }

        /// The width of square keys exactly `height` tall.
        func width(forHeight height: CGFloat) -> CGFloat {
            guard totalHeight > 0 else { return 0 }
            let gaps = LaptopDeckGeometry.rowGap * CGFloat(max(heights.count - 1, 0))
            let unit = max(height - gaps, 0) / CGFloat(totalHeight) + LaptopDeckGeometry.rowGap
            return unit * CGFloat(units)
        }

        /// The largest keyboard of this shape that fits `size`.
        func fitting(_ size: CGSize) -> CGSize {
            let height = height(forWidth: size.width)
            if height <= size.height { return CGSize(width: size.width, height: height) }
            return CGSize(width: min(width(forHeight: size.height), size.width), height: size.height)
        }
    }

    /// Between rows of keys.
    static let rowGap: CGFloat = 4
    /// Between the keyboard and the pad, and the halves and the pad.
    static let spacing: CGFloat = 10
    /// Below this the pad is too short to move a pointer with, so it goes.
    /// Measured on the pad's own surface, without its buttons. Low enough
    /// for the iPhone Duo bent like a laptop, whose pad below square keys is
    /// about 82 points tall (it was 87 before the keys kept their shape).
    static let minimumPadHeight: CGFloat = 60
    /// The same for the pad between the halves of a split keyboard.
    static let minimumSplitPadWidth: CGFloat = 160

    /// - Parameters:
    ///   - area: the deck less its safe area and margin.
    ///   - rows: the whole keyboard's rows.
    ///   - halfRows: the rows of one half, when the keyboard is split.
    ///   - keysHidden: the keys put away so the pad takes the whole deck.
    static func layout(
        in area: CGRect,
        arrangement: LaptopDeckArrangement,
        rows: Rows,
        halfRows: Rows?,
        keysHidden: Bool,
        hasButtons: Bool
    ) -> LaptopDeckGeometry {
        guard area.width > 0, area.height > 0 else { return LaptopDeckGeometry() }
        if keysHidden {
            var geometry = LaptopDeckGeometry()
            geometry.placeTrackpad(in: area, hasButtons: hasButtons, fillsWidth: true)
            return geometry
        }
        if let halfRows {
            return split(in: area, arrangement: arrangement, halves: halfRows, hasButtons: hasButtons)
        }

        let size = rows.fitting(area.size)
        var geometry = LaptopDeckGeometry()
        if arrangement.hasTrackpad {
            let lowerHeight = area.height - size.height - spacing
            if padHeight(in: lowerHeight, hasButtons: hasButtons) >= minimumPadHeight {
                let keyboardAbove = arrangement == .keyboardAboveTrackpad
                let keyboardY = keyboardAbove ? area.minY : area.maxY - size.height
                geometry.keyboard = CGRect(x: area.minX, y: keyboardY, width: size.width, height: size.height)
                let lower = CGRect(
                    x: area.minX,
                    y: keyboardAbove ? keyboardY + size.height + spacing : area.minY,
                    width: area.width,
                    height: lowerHeight
                )
                geometry.placeTrackpad(in: lower, hasButtons: hasButtons, fillsWidth: false)
                return geometry
            }
        }
        // Keyboard only, asked for or for want of room: in the middle.
        geometry.keyboard = CGRect(
            x: area.midX - size.width / 2,
            y: area.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        return geometry
    }

    /// The halves against the sides, as tall as the deck allows, from the
    /// bottom up so the thumbs reach them; the pad between them in what is
    /// left of the width.
    private static func split(
        in area: CGRect,
        arrangement: LaptopDeckArrangement,
        halves: Rows,
        hasButtons: Bool
    ) -> LaptopDeckGeometry {
        let narrowestMiddle = area.width * 0.04
        let widestHalf = max((area.width - narrowestMiddle - spacing * 2) / 2, 0)
        let size = halves.fitting(CGSize(width: widestHalf, height: area.height))
        let keysY = area.maxY - size.height
        var geometry = LaptopDeckGeometry()
        geometry.leftHalf = CGRect(x: area.minX, y: keysY, width: size.width, height: size.height)
        geometry.rightHalf = CGRect(x: area.maxX - size.width, y: keysY, width: size.width, height: size.height)
        let middle = CGRect(
            x: area.minX + size.width + spacing,
            y: area.minY,
            width: area.width - size.width * 2 - spacing * 2,
            height: area.height
        )
        if arrangement.hasTrackpad, middle.width >= minimumSplitPadWidth,
           padHeight(in: middle.height, hasButtons: hasButtons) >= minimumPadHeight {
            geometry.placeTrackpad(in: middle, hasButtons: hasButtons, fillsWidth: true)
        }
        return geometry
    }

    private static func buttonHeight(in height: CGFloat, hasButtons: Bool) -> CGFloat {
        hasButtons ? min(40, height * 0.22) : 0
    }

    /// What is left of `height` for the pad's surface once its buttons are in.
    private static func padHeight(in height: CGFloat, hasButtons: Bool) -> CGFloat {
        height - (hasButtons ? buttonHeight(in: height, hasButtons: true) + 6 : 0)
    }

    /// The pad with its two buttons below it, on the user's side, as on a
    /// laptop: the buttons sit under the thumbs whichever way round the
    /// keyboard is.
    private mutating func placeTrackpad(in lower: CGRect, hasButtons: Bool, fillsWidth: Bool) {
        let padWidth = fillsWidth ? lower.width : min(lower.width, max(lower.width * 0.72, 300))
        let buttonHeight = Self.buttonHeight(in: lower.height, hasButtons: hasButtons)
        let padFrame = CGRect(
            x: lower.midX - padWidth / 2,
            y: lower.minY,
            width: padWidth,
            height: Self.padHeight(in: lower.height, hasButtons: hasButtons)
        )
        pad = padFrame
        guard hasButtons else { return }
        let buttonY = padFrame.maxY + 6
        leftButton = CGRect(x: padFrame.minX, y: buttonY, width: padWidth / 2 - 3, height: buttonHeight)
        rightButton = CGRect(x: padFrame.midX + 3, y: buttonY, width: padWidth / 2 - 3, height: buttonHeight)
    }
}
