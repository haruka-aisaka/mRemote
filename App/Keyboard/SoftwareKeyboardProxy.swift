import SwiftUI
import UIKit
import InputCore
import SessionCore

/// The first responder while the software keyboard is up.
///
/// A hidden `UITextView` rather than a hand-written `UITextInput`: iPadOS's
/// marked-text handling - Japanese conversion, predictions, dictation - is
/// exactly what local IME mode wants, and a text view already does it right.
/// The view never keeps text. The moment nothing is marked, whatever it holds
/// has been committed, is handed to the controller and cleared; while
/// something is marked it is only mirrored into the key bar.
///
/// The physical surface is a different responder that deliberately is *not*
/// a text input (KEY-IME-02). The two are never first responder together.
final class SoftwareKeyboardProxy: UITextView, UITextViewDelegate {
    weak var controller: SoftwareKeyboardController?
    private var bar: UIView?

    init(controller: SoftwareKeyboardController) {
        self.controller = controller
        super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1), textContainer: nil)
        delegate = self
        alpha = 0.02
        backgroundColor = .clear
        textColor = .clear
        tintColor = .clear
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        autocapitalizationType = .none
        accessibilityIdentifier = "software-keyboard-proxy"
        applyMode(controller.mode)

        let host = UIHostingController(rootView: ExtendedKeyBar(controller: controller))
        host.sizingOptions = .intrinsicContentSize
        let container = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 96), inputViewStyle: .keyboard)
        container.allowsSelfSizing = true
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        bar = container
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var inputAccessoryView: UIView? {
        get { bar }
        set { bar = newValue }
    }

    /// Host IME mode asks for an ASCII keyboard, so iPadOS does no
    /// converting of its own and the host IME sees plain key positions.
    func applyMode(_ mode: SoftwareKeyboardMode) {
        keyboardType = mode == .hostIME ? .asciiCapable : .default
        if isFirstResponder { reloadInputViews() }
    }

    func textViewDidChange(_ textView: UITextView) {
        handleChange()
    }

    private func handleChange() {
        if let marked = markedTextRange {
            controller?.markedText = text(in: marked)
            return
        }
        controller?.markedText = nil
        let committed = text ?? ""
        guard !committed.isEmpty else { return }
        clear()
        controller?.commit(committed)
    }

    /// Backspace on an empty proxy is the remote's Backspace; with text in
    /// it, it edits the composition locally.
    override func deleteBackward() {
        if (text ?? "").isEmpty, markedTextRange == nil {
            controller?.press(.backspace)
        } else {
            super.deleteBackward()
        }
    }

    func confirmComposition() {
        guard markedTextRange != nil else { return }
        unmarkText()
        handleChange()
    }

    func cancelComposition() {
        guard !(text ?? "").isEmpty || markedTextRange != nil else { return }
        clear()
    }

    private func clear() {
        inputDelegate?.textWillChange(self)
        text = ""
        inputDelegate?.textDidChange(self)
    }
}

/// Puts the proxy in the hierarchy and moves first responder to it while the
/// software keyboard is visible.
struct SoftwareKeyboardHost: UIViewRepresentable {
    let controller: SoftwareKeyboardController

    func makeUIView(context: Context) -> SoftwareKeyboardProxy {
        let proxy = SoftwareKeyboardProxy(controller: controller)
        controller.proxy = proxy
        return proxy
    }

    func updateUIView(_ proxy: SoftwareKeyboardProxy, context: Context) {
        if controller.isVisible {
            if !proxy.isFirstResponder {
                DispatchQueue.main.async { _ = proxy.becomeFirstResponder() }
            }
        } else if proxy.isFirstResponder {
            _ = proxy.resignFirstResponder()
        }
    }
}
