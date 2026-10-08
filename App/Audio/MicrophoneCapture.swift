import AVFoundation
import OSLog
import AppleAdapters
import SessionCore

/// This device's microphone for the session that asked for it.
///
/// Started when the server opens its microphone and stopped when it closes
/// it or the session goes away. The input is converted to the format the
/// server chose and handed to the session's sink on the audio thread, the
/// data plane, without passing through any actor.
@MainActor
final class MicrophoneCapture {
    static let shared = MicrophoneCapture()

    private let engine = AVAudioEngine()
    private var owner: ObjectIdentifier?
    private let logger = AppLog.logger(.audio)

    /// Whether the audio session has to allow recording too.
    private(set) var isActive = false

    func start(format: MicrophoneFormat, sink: any MicrophoneSink, owner: AnyObject) async {
        stop()
        guard await AVAudioApplication.requestRecordPermission() else {
            logger.info("microphone permission denied")
            return
        }
        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(format.sampleRate),
            channels: AVAudioChannelCount(format.channels),
            interleaved: true
        ) else { return }
        do {
            isActive = true
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers])
            try session.setActive(true)
            let input = engine.inputNode
            let source = input.outputFormat(forBus: 0)
            guard source.sampleRate > 0, let converter = AVAudioConverter(from: source, to: target) else {
                isActive = false
                return
            }
            input.installTap(onBus: 0, bufferSize: 2048, format: source) { buffer, _ in
                Self.convert(buffer, with: converter, to: target, sink: sink)
            }
            try engine.start()
            self.owner = ObjectIdentifier(owner)
            logger.info("microphone capture \(format.sampleRate, privacy: .public) Hz x\(format.channels, privacy: .public)")
        } catch {
            isActive = false
            engine.inputNode.removeTap(onBus: 0)
            logger.error("microphone capture failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Stops only for the session that started it, unless told to stop.
    func stop(for owner: AnyObject? = nil) {
        if let owner, self.owner != ObjectIdentifier(owner) { return }
        guard isActive || engine.isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isActive = false
        self.owner = nil
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.mixWithOthers])
    }

    /// On the audio thread: no actor, no allocation beyond the output.
    private nonisolated static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to target: AVAudioFormat,
        sink: any MicrophoneSink
    ) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, output.frameLength > 0, let samples = output.int16ChannelData else { return }
        let bytes = Int(output.frameLength) * Int(target.channelCount) * 2
        sink.send(pcm: Data(bytes: samples[0], count: bytes))
    }
}
