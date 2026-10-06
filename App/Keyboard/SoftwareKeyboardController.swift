import Foundation
import Observation
import InputCore
import SessionCore

/// The software keyboard of one session (docs/input-design.md section 10).
///
/// The text proxy reports what iPadOS committed and the key bar reports
/// taps; this turns both into host input through `SoftwareKeyboardComposer`,
/// whose chords are complete in themselves, so closing the keyboard has
/// nothing to release on the host - only the local latches.
@MainActor
@Observable
final class SoftwareKeyboardController {
    private(set) var isVisible = false
    private(set) var mode: SoftwareKeyboardMode
    /// Local IME composition not yet committed. Shown in the bar, never sent.
    var markedText: String?
    private var composer: SoftwareKeyboardComposer

    @ObservationIgnored weak var proxy: SoftwareKeyboardProxy?
    @ObservationIgnored private let send: (SoftwareKeyboardOutput) -> Void
    @ObservationIgnored private let canSend: () -> Bool

    init(
        mode: SoftwareKeyboardMode,
        layout: KeyboardLayoutPreference,
        canSend: @escaping () -> Bool,
        send: @escaping (SoftwareKeyboardOutput) -> Void
    ) {
        self.mode = mode
        self.composer = SoftwareKeyboardComposer(mode: mode, layout: layout)
        self.canSend = canSend
        self.send = send
    }

    var hasMarkedText: Bool { !(markedText ?? "").isEmpty }

    func latch(_ modifier: VirtualModifier) -> VirtualModifierState.Latch {
        composer.modifiers.latch(modifier)
    }

    func show() {
        isVisible = true
    }

    /// docs/ui-flow.md section 9: closing releases every virtual modifier
    /// and gives the keyboard back to the physical surface.
    func hide() {
        cancelComposition()
        composer.releaseModifiers()
        isVisible = false
    }

    /// Refused while composing: the marked text has to be committed or
    /// cancelled first, or it would be typed under the wrong mode.
    func setMode(_ newMode: SoftwareKeyboardMode) {
        guard !hasMarkedText, newMode != mode else { return }
        composer.releaseModifiers()
        mode = newMode
        composer.mode = newMode
        proxy?.applyMode(newMode)
    }

    func commit(_ text: String) {
        deliver(composer.commit(text))
    }

    func press(_ key: ExtendedKey) {
        // Esc first cancels a composition; only without one is it the
        // remote's Escape.
        if key == .escape, hasMarkedText {
            cancelComposition()
            return
        }
        guard !hasMarkedText else { return }
        deliver(composer.press(key))
    }

    func tapModifier(_ modifier: VirtualModifier) {
        guard !hasMarkedText else { return }
        composer.tapModifier(modifier)
    }

    func confirmComposition() {
        proxy?.confirmComposition()
    }

    func cancelComposition() {
        proxy?.cancelComposition()
        markedText = nil
    }

    private func deliver(_ outputs: [SoftwareKeyboardOutput]) {
        guard canSend() else { return }
        outputs.forEach(send)
    }
}
