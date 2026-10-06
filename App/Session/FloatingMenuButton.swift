import SwiftUI

/// docs/ui-flow.md section 6.1: one button over the desktop, movable along
/// the edges, fading when left alone so it hides as little of the remote
/// screen as possible.
struct FloatingMenuButton: View {
    let action: () -> Void

    /// Which side the button snaps to, and how far down it sits as a fraction
    /// of the height, so a rotation keeps it on the same edge.
    @AppStorage("floating-menu-trailing") private var isTrailing = true
    @AppStorage("floating-menu-vertical") private var verticalFraction = 0.85
    @State private var dragOffset: CGSize = .zero
    @State private var isIdle = false
    @State private var idleTask: Task<Void, Never>?

    private let size: CGFloat = 52
    private let inset: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            let bounds = proxy.frame(in: .local)
            Button(action: {
                wake()
                action()
            }) {
                Image(systemName: "ellipsis.circle.fill")
                    .font(.system(size: 44))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.6))
                    .frame(width: size, height: size)
                    .contentShape(Circle())
            }
            .accessibilityIdentifier("session-menu-button")
            .accessibilityLabel("セッションメニュー")
            .accessibilityHint("切り替え、キーボード、クリップボード、切断など")
            .opacity(isIdle ? 0.35 : 1)
            .position(position(in: bounds))
            .offset(dragOffset)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { value in
                        wake()
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        let dropped = CGPoint(
                            x: position(in: bounds).x + value.translation.width,
                            y: position(in: bounds).y + value.translation.height
                        )
                        isTrailing = dropped.x > bounds.midX
                        verticalFraction = min(max(dropped.y / max(bounds.height, 1), 0.1), 0.9)
                        dragOffset = .zero
                    }
            )
            .onHover { hovering in if hovering { wake() } }
            .animation(.easeOut(duration: 0.2), value: isTrailing)
            .animation(.easeOut(duration: 0.4), value: isIdle)
        }
        .onAppear { wake() }
    }

    private func position(in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: isTrailing ? bounds.maxX - inset - size / 2 : bounds.minX + inset + size / 2,
            y: min(max(bounds.height * verticalFraction, size), bounds.height - size)
        )
    }

    private func wake() {
        isIdle = false
        idleTask?.cancel()
        idleTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            isIdle = true
        }
    }
}
