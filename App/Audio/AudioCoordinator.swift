import AVFoundation
import AppleAdapters

/// The one audio engine, playing exactly one session: the focused one.
///
/// docs/architecture.md section 8. Every session keeps its own ring and its
/// bridge drops PCM while it is not focused, so switching is: point the
/// engine at the new session's ring, discard that ring's backlog, and build a
/// source node for its format. Nothing from two sessions is ever mixed.
@MainActor
final class AudioCoordinator {
    static let shared = AudioCoordinator()

    private let engine = AVAudioEngine()
    private var sourceNode: AVAudioSourceNode?
    private var stream: PCMAudioStream?
    private var nodeFormat: PCMAudioStream.Format?
    /// The stream the current node renders. A switch between two sessions
    /// with the same format still needs a new node, or the old session keeps
    /// playing.
    private weak var nodeStream: PCMAudioStream?
    private var isMuted = false
    private var isSuspended = false
    private var observers: [NSObjectProtocol] = []
    private let logger = AppLog.logger(.app)

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let ended = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .ended
            MainActor.assumeIsolated { if ended { self?.restart() } }
        })
        // A route change (headphones in or out) can change the hardware
        // format, after which AVAudioEngine stops and has to be rebuilt.
        observers.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild(force: true) }
        })
    }

    /// Plays `stream`, or nothing. Called whenever focus or the local mute
    /// changes.
    func setFocused(_ stream: PCMAudioStream?, muted: Bool) {
        if stream !== self.stream {
            self.stream?.setFormatObserver(nil)
            self.stream = stream
            // What the newly focused session said while in the background is
            // not live any more.
            stream?.discardBacklog()
            stream?.setFormatObserver { [weak self] _ in
                Task { @MainActor in self?.rebuild(force: false) }
            }
        }
        isMuted = muted
        rebuild(force: false)
    }

    /// The app went to the background: no audio is played from there
    /// (keeping a connection alive is not a reason to hold the audio session).
    func suspend() {
        isSuspended = true
        engine.pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func resume() {
        isSuspended = false
        stream?.discardBacklog()
        rebuild(force: true)
    }

    private func restart() {
        stream?.discardBacklog()
        rebuild(force: true)
    }

    private func rebuild(force: Bool) {
        let format = stream?.format
        if force || format != nodeFormat || stream !== nodeStream {
            if let sourceNode {
                engine.detach(sourceNode)
                self.sourceNode = nil
            }
            nodeFormat = nil
            nodeStream = nil
            if let stream, let format,
               let avFormat = AVAudioFormat(
                   standardFormatWithSampleRate: format.sampleRate,
                   channels: AVAudioChannelCount(format.channels)
               ) {
                let channels = format.channels
                // Unowned on purpose: retaining from the render thread is the
                // one thing it must not do, and the coordinator detaches the
                // node before it lets go of the stream.
                let node = AVAudioSourceNode(format: avFormat) { [unowned stream] _, _, frameCount, list in
                    stream.render(
                        frameCount: Int(frameCount),
                        channels: channels,
                        into: UnsafeMutableAudioBufferListPointer(list)
                    )
                    return noErr
                }
                engine.attach(node)
                engine.connect(node, to: engine.mainMixerNode, format: avFormat)
                sourceNode = node
                nodeFormat = format
                nodeStream = stream
            }
        }
        sourceNode?.volume = isMuted ? 0 : 1

        guard sourceNode != nil, !isSuspended else {
            if sourceNode == nil, engine.isRunning { engine.pause() }
            return
        }
        guard !engine.isRunning else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            // Mixes with other apps: a remote desktop's sounds are rarely a
            // reason to stop the user's music.
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try engine.start()
        } catch {
            logger.error("audio engine failed to start: \(String(describing: error), privacy: .public)")
        }
    }
}
