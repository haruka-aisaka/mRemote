import UIKit

@MainActor
final class IMEInputProxy: UITextView {
    enum Mode: String {
        case hostIME
        case localIME
    }

    var onMarkedText: ((String?) -> Void)?
    var onHostASCII: ((String, UInt64) -> Void)?
    var onCommittedText: ((String, UInt64) -> Void)?
    var onDiagnostic: ((String) -> Void)?
    var onWillResignInput: (() -> Void)?

    private(set) var mode: Mode = .hostIME
    private(set) var generation: UInt64 = 0
    private var isResetting = false
    private var isHandlingInsert = false

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        configureView()
        applyTraits(for: .hostIME)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
        applyTraits(for: .hostIME)
    }

    func prepare(mode: Mode, generation: UInt64) {
        let wasFirstResponder = isFirstResponder
        if wasFirstResponder { _ = resignForReset(invalidateGeneration: false) }

        resetCompositionAndText()

        self.mode = mode
        self.generation = generation
        applyTraits(for: mode)
        onMarkedText?(nil)
        onDiagnostic?("proxy mode=\(mode.rawValue) keyboardType=\(keyboardType.rawValue) g=\(generation)")

        if wasFirstResponder {
            becomeFirstResponder()
            reloadInputViews()
        }
    }

    func cancelComposition() {
        isResetting = true
        if let range = markedTextRange {
            replace(range, withText: "")
        }
        isResetting = false
        onMarkedText?(nil)
    }

    override func resignFirstResponder() -> Bool {
        resignForReset(invalidateGeneration: true)
    }

    override func insertText(_ text: String) {
        guard !isResetting else {
            super.insertText(text)
            return
        }

        switch mode {
        case .hostIME:
            guard text.unicodeScalars.allSatisfy(\.isASCII) else {
                onDiagnostic?("host proxy rejected non-ASCII UTF16=\(text.utf16.count)")
                return
            }
            super.insertText(text)
            onHostASCII?(text, generation)
            if markedTextRange == nil {
                // The proxy is not an editor. Keeping no host text makes every
                // callback an isolated candidate for scan-code conversion.
                self.text = ""
                selectedRange = NSRange(location: 0, length: 0)
            }
        case .localIME:
            isHandlingInsert = true
            super.insertText(text)
            isHandlingInsert = false
            onCommittedText?(text, generation)
            onMarkedText?(currentMarkedText)
        }
    }

    override func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
        super.setMarkedText(markedText, selectedRange: selectedRange)
        guard !isResetting, !isHandlingInsert else { return }
        let current = currentMarkedText ?? markedText
        onMarkedText?(current)
        onDiagnostic?("MARKED UTF16=\(current?.utf16.count ?? 0)")
    }

    override func unmarkText() {
        let committedWithoutInsert = currentMarkedText
        super.unmarkText()
        guard !isResetting, !isHandlingInsert else { return }
        if mode == .localIME, let committedWithoutInsert, !committedWithoutInsert.isEmpty {
            onCommittedText?(committedWithoutInsert, generation)
        }
        onMarkedText?(nil)
    }

    override func deleteBackward() {
        let wasComposing = markedTextRange != nil
        super.deleteBackward()
        if wasComposing {
            onMarkedText?(currentMarkedText)
        } else {
            onDiagnostic?("proxy deleteBackward mode=\(mode.rawValue) (not forwarded in Phase 0)")
        }
    }

    private var currentMarkedText: String? {
        guard let markedTextRange else { return nil }
        return text(in: markedTextRange)
    }

    private func resignForReset(invalidateGeneration: Bool) -> Bool {
        resetCompositionAndText()
        if invalidateGeneration {
            // Advance the router generation before UIKit gets a chance to
            // synthesize any final UITextInput callback during resignation.
            onWillResignInput?()
        }
        let result = super.resignFirstResponder()
        onDiagnostic?("proxy resigned invalidate=\(invalidateGeneration)")
        return result
    }

    private func resetCompositionAndText() {
        isResetting = true
        if let range = markedTextRange {
            replace(range, withText: "")
        }
        text = ""
        selectedRange = NSRange(location: 0, length: 0)
        isResetting = false
        onMarkedText?(nil)
    }

    private func configureView() {
        backgroundColor = UIColor.secondarySystemBackground
        layer.borderColor = UIColor.tertiaryLabel.cgColor
        layer.borderWidth = 1
        layer.cornerRadius = 8
        font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textColor = .label
        isScrollEnabled = true
        accessibilityLabel = "Software keyboard UITextInput proxy"
    }

    private func applyTraits(for mode: Mode) {
        textContentType = nil
        autocapitalizationType = .none
        switch mode {
        case .hostIME:
            keyboardType = .asciiCapable
            autocorrectionType = .no
            spellCheckingType = .no
            smartQuotesType = .no
            smartDashesType = .no
            smartInsertDeleteType = .no
        case .localIME:
            keyboardType = .default
            autocorrectionType = .default
            spellCheckingType = .default
            smartQuotesType = .default
            smartDashesType = .default
            smartInsertDeleteType = .default
        }
    }
}
