import SwiftUI
import InputCore
import SessionCore

/// docs/ui-flow.md section 9: Esc, Tab, Ctrl, Alt, Shift, Win, arrows,
/// Delete, 無変換 and 変換 above the system keyboard, the mode always named,
/// and 確定/キャンセル while something is being composed.
struct ExtendedKeyBar: View {
    @Bindable var controller: SoftwareKeyboardController

    var body: some View {
        VStack(spacing: 6) {
            if let marked = controller.markedText, !marked.isEmpty {
                compositionBar(marked)
            }
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        key("Esc", .escape, allowedWhileComposing: true)
                        key("Tab", .tab)
                        modifier("Ctrl", .control)
                        modifier("Alt", .alt)
                        modifier("Shift", .shift)
                        modifier("Win", .windows)
                        key("無変換", .nonConvert)
                        key("変換", .convert)
                        symbolKey("arrow.left", .left, label: "左")
                        symbolKey("arrow.down", .down, label: "下")
                        symbolKey("arrow.up", .up, label: "上")
                        symbolKey("arrow.right", .right, label: "右")
                        key("Home", .home)
                        key("End", .end)
                        key("PgUp", .pageUp)
                        key("PgDn", .pageDown)
                        key("Del", .deleteForward)
                        if controller.canPaste {
                            pasteToggle
                        }
                    }
                    .padding(.horizontal, 8)
                }
                Picker("入力モード", selection: Binding(
                    get: { controller.mode },
                    set: { controller.setMode($0) }
                )) {
                    Text("手元IME").tag(SoftwareKeyboardMode.localIME)
                    Text("ホストIME").tag(SoftwareKeyboardMode.hostIME)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(controller.hasMarkedText)
                .accessibilityIdentifier("software-keyboard-mode")
                Button {
                    controller.hide()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .frame(minWidth: 44, minHeight: 36)
                }
                .accessibilityLabel("キーボードを閉じる")
                .accessibilityIdentifier("software-keyboard-close")
                .padding(.trailing, 8)
            }
        }
        .padding(.vertical, 6)
    }

    /// Arming is the consent the paste fallback asks for, so the label says
    /// what it does to the remote clipboard.
    private var pasteToggle: some View {
        Button {
            controller.togglePasteNextCommit()
        } label: {
            Label(
                controller.pastesNextCommit ? "次の入力を貼り付けで送る（クリップボード上書き）" : "貼り付けで送る",
                systemImage: "doc.on.clipboard"
            )
        }
        .modifierStyle(isOn: controller.pastesNextCommit)
        .accessibilityHint("次に確定した文字を、リモートのクリップボードを上書きして貼り付けで送ります。Unicode 入力を受け付けないアプリ向け")
        .accessibilityValue(controller.pastesNextCommit ? "オン" : "オフ")
        .accessibilityIdentifier("software-keyboard-paste-next")
    }

    private func compositionBar(_ marked: String) -> some View {
        HStack {
            Text(marked)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary, style: StrokeStyle(dash: [4])))
                .accessibilityLabel("変換中: \(marked)")
            Text("未確定（まだ送信されていません）")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("確定") { controller.confirmComposition() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("composition-confirm")
            Button("キャンセル") { controller.cancelComposition() }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("composition-cancel")
        }
        .padding(.horizontal, 8)
    }

    private func key(_ title: String, _ key: ExtendedKey, allowedWhileComposing: Bool = false) -> some View {
        Button(title) { controller.press(key) }
            .buttonStyle(.bordered)
            .disabled(controller.hasMarkedText && !allowedWhileComposing)
            .accessibilityIdentifier("key-\(key.rawValue)")
    }

    private func symbolKey(_ symbol: String, _ key: ExtendedKey, label: String) -> some View {
        Button {
            controller.press(key)
        } label: {
            Image(systemName: symbol)
        }
        .buttonStyle(.bordered)
        .disabled(controller.hasMarkedText)
        .accessibilityLabel(label)
        .accessibilityIdentifier("key-\(key.rawValue)")
    }

    /// One-shot and lock are told apart by shape and text, not colour alone:
    /// filled for one-shot, filled with a lock for locked.
    @ViewBuilder
    private func modifier(_ title: String, _ modifier: VirtualModifier) -> some View {
        let latch = controller.latch(modifier)
        Button {
            controller.tapModifier(modifier)
        } label: {
            HStack(spacing: 2) {
                if latch == .locked { Image(systemName: "lock.fill").font(.caption2) }
                Text(title)
            }
        }
        .modifierStyle(isOn: latch != .off)
        .disabled(controller.hasMarkedText)
        .accessibilityValue(latch == .off ? "オフ" : latch == .oneShot ? "次の1キー" : "固定")
        .accessibilityIdentifier("modifier-\(modifier.rawValue)")
    }
}

private extension View {
    @ViewBuilder
    func modifierStyle(isOn: Bool) -> some View {
        if isOn {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }
}
