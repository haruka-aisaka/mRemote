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

    /// Images and files, where the session can carry them.
    var remoteHasImage: Bool { get }
    var remoteHasFiles: Bool { get }
    func offerClipboardImage(png: Data?, dib: Data?) async throws
    func offerClipboardFiles(_ files: [ClipboardFile]) async throws
    func fetchRemoteClipboardImage() async throws -> RemoteClipboardImage
    func fetchRemoteClipboardFiles() async throws -> [ClipboardFile]
}

/// A file going over the clipboard: its name, without folders, and bytes.
public struct ClipboardFile: Hashable, Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

/// An image the remote copied, as it came.
public enum RemoteClipboardImage: Hashable, Sendable {
    case png(Data)
    /// CF_DIB: a BITMAPINFO header and the pixels, no file header.
    case dib(Data)
}

public extension ClipboardCapableSession {
    var remoteHasImage: Bool { false }
    var remoteHasFiles: Bool { false }
    func offerClipboardImage(png: Data?, dib: Data?) async throws { throw ClipboardTransferError.unavailable }
    func offerClipboardFiles(_ files: [ClipboardFile]) async throws { throw ClipboardTransferError.unavailable }
    func fetchRemoteClipboardImage() async throws -> RemoteClipboardImage {
        throw ClipboardTransferError.unavailable
    }
    func fetchRemoteClipboardFiles() async throws -> [ClipboardFile] {
        throw ClipboardTransferError.unavailable
    }
}

/// The format the server opened the microphone with: interleaved signed
/// 16-bit little-endian PCM.
public struct MicrophoneFormat: Hashable, Sendable {
    public let sampleRate: Int
    public let channels: Int

    public init(sampleRate: Int, channels: Int) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Where captured PCM goes, on the data plane like input: synchronous and
/// safe from the audio thread.
public protocol MicrophoneSink: AnyObject, Sendable {
    func send(pcm: Data)
}

/// docs/architecture.md section 4: a session that can take the microphone.
public protocol MicrophoneCapableSession: RemoteSession {
    nonisolated var microphoneSink: any MicrophoneSink { get }
}
