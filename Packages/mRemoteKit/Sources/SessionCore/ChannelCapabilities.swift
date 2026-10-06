import Foundation

/// A session's audio, as something the app's audio engine can play.
///
/// Deliberately empty here: the PCM transport is a lock-free ring that the
/// app owns next to `AVAudioEngine`, and SessionCore has no reason to know
/// its shape. The app recognises its own concrete type.
public protocol RemoteAudioSource: AnyObject, Sendable {}

/// docs/architecture.md section 4: audio is a capability, not part of every
/// session. A future SSH terminal never has to pretend to have a speaker.
public protocol AudioCapableSession: RemoteSession {
    nonisolated var audioSource: any RemoteAudioSource { get }
}

public enum ClipboardTransferError: Error, Hashable, Sendable {
    /// The channel is not negotiated, or the profile turned it off.
    case unavailable
    /// The remote side did not answer in time.
    case timedOut
    /// Over the size limit, or not representable as Windows text.
    case unsupportedContent
    /// The remote has no text to give.
    case nothingToCopy
    case failed
}

/// Plain-text clipboard in both directions, always started by the user.
///
/// docs/architecture.md section 9: nothing here watches the local pasteboard
/// or pushes on its own. `remoteHasText` reflects the server's latest format
/// list; the text itself is only fetched when the user asks for it.
public protocol ClipboardCapableSession: RemoteSession {
    var remoteHasText: Bool { get }

    /// Makes `text` the remote clipboard. Returns once the server has
    /// acknowledged the offer, so a paste chord sent afterwards finds it.
    func offerClipboardText(_ text: String) async throws

    func fetchRemoteClipboardText() async throws -> String
}
