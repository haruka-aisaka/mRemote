import SwiftUI

/// The strip along a docked deck's top edge: dragged up or down, it moves
/// the line between the desktop and the deck.
struct DeckResizeHandle: View {
    /// The deck's share of the height, written as the drag goes.
    @Binding var fraction: Double
    /// Where a double tap puts it back.
    var standardFraction = DeckLayout.standardFraction
    let screenHeight: CGFloat
    @State private var startFraction: Double?

    var body: some View {
        ZStack {
            Color.black
            Capsule()
                .fill(.white.opacity(0.45))
                .frame(width: 44, height: 5)
        }
        .frame(height: DeckLayout.resizeHandleHeight)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { fraction = standardFraction }
        .gesture(
            // Global, because the handle moves with the drag.
            DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in
                    let start = startFraction ?? fraction
                    startFraction = start
                    fraction = DeckLayout.clampFraction(
                        start - Double(value.translation.height / max(screenHeight, 1))
                    )
                }
                .onEnded { _ in startFraction = nil }
        )
        .accessibilityElement()
        .accessibilityLabel("手元キーボードの高さ")
        .accessibilityValue("\(Int((fraction * 100).rounded()))%")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 0.05 : -0.05
            fraction = DeckLayout.clampFraction(fraction + step)
        }
        .accessibilityAction(named: "元の高さに戻す") { fraction = standardFraction }
        .accessibilityIdentifier("laptop-deck-resize-handle")
    }
}

/// The deck as a panel over the desktop: the bar on top moves it, the grip
/// at the bar's right end resizes it. Both live on the bar so that no key
/// or trackpad corner is given up to them.
struct FloatingDeckPanel<Content: View>: View {
    @Binding var frame: FloatingDeckFrame
    @ViewBuilder let content: Content
    @State private var moveTranslation: CGSize = .zero
    @State private var resizeTranslation: CGSize = .zero

    private static var barHeight: CGFloat { 26 }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let live = frame
                .moved(by: moveTranslation, in: size)
                .resized(byDraggingTopRight: resizeTranslation, in: size)
            let rect = live.rect(in: size)
            VStack(spacing: 0) {
                bar(in: size, live: live)
                content
            }
            .frame(width: rect.width, height: rect.height)
            .background(Color(white: 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.18))
            )
            .shadow(color: .black.opacity(0.5), radius: 12)
            .position(x: rect.midX, y: rect.midY)
        }
    }

    private func bar(in size: CGSize, live: FloatingDeckFrame) -> some View {
        HStack(spacing: 0) {
            ZStack {
                Color.clear
                Capsule()
                    .fill(.white.opacity(0.45))
                    .frame(width: 44, height: 5)
                    // Centred on the panel, past the grip's width.
                    .padding(.leading, 44)
            }
            .contentShape(Rectangle())
            .gesture(
                // Global, because the bar moves with the drag.
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { moveTranslation = $0.translation }
                    .onEnded { _ in
                        frame = live
                        moveTranslation = .zero
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("手元キーボードを移動")
            .accessibilityIdentifier("laptop-deck-move-handle")
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 44, height: Self.barHeight)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2, coordinateSpace: .global)
                        .onChanged { resizeTranslation = $0.translation }
                        .onEnded { _ in
                            frame = live
                            resizeTranslation = .zero
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("手元キーボードの大きさ")
                .accessibilityIdentifier("laptop-deck-size-handle")
        }
        .frame(height: Self.barHeight)
    }
}
