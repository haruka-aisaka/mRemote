import CoreAudio
import Foundation
import SessionCore

/// One session's PCM on its way to the speaker.
///
/// The producer is the session's rdpsnd callback, the consumer the render
/// callback of `AudioCoordinator`'s source node. Between them sits
/// `mr_pcm_ring`, a lock-free SPSC ring, because docs/architecture.md
/// section 8 forbids locks, allocation and actor hops on the render thread.
/// The format lives behind a lock that only the producer and the main actor
/// take; the render callback is handed the channel count it was built with.
final class PCMAudioStream: RemoteAudioSource, @unchecked Sendable {
    struct Format: Hashable, Sendable {
        let sampleRate: Double
        let channels: Int
    }

    /// Half a second of 48 kHz stereo: enough to ride out scheduling jitter,
    /// short enough that a backlog is never mistaken for live audio.
    static let capacityBytes = 48_000 * 2 * 2 / 2
    /// The most frames one render call is expected to ask for; the scratch
    /// buffer is sized once so rendering never allocates.
    static let maximumRenderFrames = 4_096

    private let ring: OpaquePointer
    private let scratch: UnsafeMutablePointer<Int16>
    private let lock = NSLock()
    private var currentFormat: Format?
    private var formatObserver: (@Sendable (Format) -> Void)?
    private(set) var droppedPackets = 0

    init() {
        guard let ring = mr_pcm_ring_create(Self.capacityBytes) else {
            fatalError("could not allocate the PCM ring")
        }
        self.ring = ring
        scratch = .allocate(capacity: Self.maximumRenderFrames * 2)
    }

    deinit {
        mr_pcm_ring_destroy(ring)
        scratch.deallocate()
    }

    var format: Format? {
        lock.lock()
        defer { lock.unlock() }
        return currentFormat
    }

    func setFormatObserver(_ observer: (@Sendable (Format) -> Void)?) {
        lock.lock()
        formatObserver = observer
        lock.unlock()
    }

    /// Producer side. Returns false when the ring is full, which the bridge
    /// reports as backpressure; the server is confirmed either way.
    @discardableResult
    func push(_ bytes: UnsafeRawBufferPointer, sampleRate: Double, channels: Int) -> Bool {
        let format = Format(sampleRate: sampleRate, channels: channels)
        lock.lock()
        let changed = format != currentFormat
        if changed { currentFormat = format }
        let observer = formatObserver
        lock.unlock()
        if changed { observer?(format) }

        guard let base = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
              mr_pcm_ring_write(ring, base, bytes.count) == 1 else {
            lock.lock()
            droppedPackets += 1
            lock.unlock()
            return false
        }
        return true
    }

    /// Consumer side: drops the backlog so a session coming to the front
    /// does not play what it said while it was in the background.
    func discardBacklog() {
        mr_pcm_ring_discard(ring)
    }

    /// Render callback body. Interleaved Int16 in, one deinterleaved Float32
    /// buffer per channel out, silence for whatever the ring cannot supply.
    func render(
        frameCount: Int,
        channels: Int,
        into buffers: UnsafeMutableAudioBufferListPointer
    ) {
        let frames = min(frameCount, Self.maximumRenderFrames)
        let wanted = frames * channels * 2
        let read = scratch.withMemoryRebound(to: UInt8.self, capacity: wanted) {
            mr_pcm_ring_read(ring, $0, wanted)
        }
        let readFrames = read / (channels * 2)
        for (channel, buffer) in buffers.enumerated() where channel < channels {
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<frameCount {
                samples[frame] = frame < readFrames
                    ? Float(scratch[frame * channels + channel]) / 32_768
                    : 0
            }
        }
    }
}
