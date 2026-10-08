import SwiftUI

/// docs/ui-flow.md section 6.1: one button over the desktop, movable along
/// the edges, fading when left alone so it hides as little of the remote
/// screen as possible. A keyboard button rides above it, as in the Windows
/// App: the two move together.
struct FloatingMenuButton: View {
    /// The keyboard button's state and what tapping it does.
    struct KeyboardToggle {
        var isShowingKeyboard: Bool
        var isEnabled: Bool
        var toggle: () -> Void
    }

    var keyboard: KeyboardToggle?
    let action: () -> Void

    /// Which side the button snaps to, and how far down it sits as a fraction
    /// of the height, so a rotation keeps it on the same edge.
    @AppStorage("floating-menu-trailing") private var isTrailing = true
    @AppStorage("floating-menu-vertical") private var verticalFraction = 0.85
    @State private var dragOffset: CGSize = .zero
    @State private var isIdle = false
    @State private var idleTask: Task<Void, Never>?
    /// The top of a keyboard docked along the bottom of the screen, in
    /// screen points: the buttons keep above it rather than behind it.
    @State private var keyboardTop: CGFloat?

    private let size: CGFloat = 52
    private let inset: CGFloat = 16
    private let spacing: CGFloat = 8

    /// The menu button stays where it was put; the keyboard button sits
    /// above it, so the pair is this much taller.
    private var raise: CGFloat { keyboard == nil ? 0 : size + spacing }

    var body: some View {
        GeometryReader { proxy in
            let global = proxy.frame(in: .global)
            let visibleHeight = keyboardTop.map { min(max($0 - global.minY, 0), global.height) } ?? global.height
            let bounds = CGRect(x: 0, y: 0, width: global.width, height: visibleHeight)
            VStack(spacing: spacing) {
                if let keyboard {
                    Button(action: {
                        wake()
                        keyboard.toggle()
                    }) {
                        Image(systemName: keyboard.isShowingKeyboard ? "keyboard.chevron.compact.down.fill" : "keyboard.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.6), in: Circle())
                            .frame(width: size, height: size)
                            .contentShape(Circle())
                    }
                    .disabled(!keyboard.isEnabled)
                    .accessibilityIdentifier("session-keyboard-button")
                    .accessibilityLabel(keyboard.isShowingKeyboard ? "キーボードを隠す" : "キーボードを表示")
                }
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
            }
            .opacity(isIdle ? 0.35 : 1)
            .position(position(in: bounds).applying(.init(translationX: 0, y: -raise / 2)))
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
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
                  let screen = (note.object as? UIScreen) ?? UIApplication.shared.connectedScenes
                    .compactMap({ ($0 as? UIWindowScene)?.screen }).first else { return }
            // Floating and split iPad keyboards do not cover a band.
            let docked = end.maxY >= screen.bounds.maxY - 1 && end.width >= screen.bounds.width - 1
            withAnimation(.easeOut(duration: 0.25)) {
                keyboardTop = docked && end.minY < screen.bounds.maxY - 1 ? end.minY : nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.25)) { keyboardTop = nil }
        }
    }

    private func position(in bounds: CGRect) -> CGPoint {
        CGPoint(
            x: isTrailing ? bounds.maxX - inset - size / 2 : bounds.minX + inset + size / 2,
            y: min(max(bounds.height * verticalFraction, size + raise), bounds.height - size)
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
