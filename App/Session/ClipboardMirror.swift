import Foundation

/// The bookkeeping that keeps the Mac's pasteboard and a session's remote
/// clipboard the same without either echoing the other.
///
/// On the Mac the clipboard follows the user both ways on its own: whatever
/// was copied on the Mac is offered to Windows when the session has the
/// keyboard, and whatever Windows copies is written to the Mac's pasteboard.
/// The pasteboard is only read when its change count has moved, and a change
/// this mirror made itself is never sent back (docs/requirements.md CLP-03).
struct ClipboardMirror {
    /// The pasteboard change count last dealt with. Nil until the first
    /// look, so what the Mac already holds is offered when a session starts.
    private(set) var handledChangeCount: Int?
    /// The text both sides hold, when they hold the same text, so a copy that
    /// comes straight back is not sent again.
    private(set) var syncedText: String?

    /// Whether the pasteboard has changed since it was last dealt with; the
    /// count is taken as dealt with either way.
    mutating func takeLocalChange(changeCount: Int) -> Bool {
        defer { handledChangeCount = changeCount }
        return handledChangeCount != changeCount
    }

    /// Local text about to be offered: false when the remote already has it.
    mutating func shouldOffer(_ text: String) -> Bool {
        guard text != syncedText else { return false }
        syncedText = text
        return true
    }

    /// Remote text about to be written to the pasteboard: false when the
    /// pasteboard already has it (the server announcing back what it was
    /// just given).
    mutating func shouldWrite(_ text: String) -> Bool {
        guard text != syncedText else { return false }
        syncedText = text
        return true
    }

    /// After writing the pasteboard: that change is this mirror's own.
    mutating func wrote(changeCount: Int) {
        handledChangeCount = changeCount
    }

    /// Something other than text went across, or the remote copied anew:
    /// no text is known to be on both sides any more.
    mutating func forgetText() {
        syncedText = nil
    }
}
