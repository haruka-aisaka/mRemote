import CoreAudio
import XCTest
import AppleAdapters
import Persistence
import SessionCore
@testable import mRemote

/// Phase 5 pieces that need no server: the PCM path from push to rendered
/// samples, and the clipboard actions against the fake session.
@MainActor
final class ChannelTests: XCTestCase {
    // MARK: - Audio

    private func render(_ stream: PCMAudioStream, frames: Int, channels: Int) -> [[Float]] {
        let list = AudioBufferList.allocate(maximumBuffers: channels)
        let storage = (0..<channels).map { _ in
            let samples = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            samples.initialize(repeating: -1, count: frames)
            return samples
        }
        defer {
            storage.forEach { $0.deallocate() }
            free(list.unsafeMutablePointer)
        }
        for channel in 0..<channels {
            list[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(frames * MemoryLayout<Float>.size),
                mData: storage[channel]
            )
        }
        stream.render(frameCount: frames, channels: channels, into: list)
        return storage.map { Array(UnsafeBufferPointer(start: $0, count: frames)) }
    }

    func testPCMIsDeinterleavedScaledAndPaddedWithSilence() {
        let stream = PCMAudioStream()
        // Two stereo frames: (16384, -32768), (0, 32767), then silence up to
        // the priming amount, so playback starts at once.
        var samples: [Int16] = [16_384, -32_768, 0, 32_767]
        samples += [Int16](repeating: 0, count: (PCMAudioStream.primingFrames - 2) * 2)
        samples.withUnsafeBytes {
            XCTAssertTrue(stream.push($0, sampleRate: 48_000, channels: 2))
        }
        XCTAssertEqual(stream.format, .init(sampleRate: 48_000, channels: 2))
        let output = render(stream, frames: 3, channels: 2)
        XCTAssertEqual(output[0], [0.5, 0, 0])
        XCTAssertEqual(output[1][0], -1)
        XCTAssertEqual(output[1][1], 32_767.0 / 32_768.0, accuracy: 1e-6)
        let rest = PCMAudioStream.primingFrames - 3
        XCTAssertEqual(render(stream, frames: rest + 1, channels: 2)[0][rest], 0,
                       "an underrun plays silence, not stale samples")
    }

    func testPlaybackWaitsForThePrimingAmountAfterRunningDry() {
        let stream = PCMAudioStream()
        let sample: [Int16] = [16_384]
        sample.withUnsafeBytes { _ = stream.push($0, sampleRate: 48_000, channels: 1) }
        // Less than the priming amount is held back, not played at once...
        XCTAssertEqual(render(stream, frames: 1_000, channels: 1)[0][0], 0)
        // ...until it has waited the priming time: a short sound still plays.
        let waits = PCMAudioStream.primingFrames / 1_000
        for _ in 1..<waits { _ = render(stream, frames: 1_000, channels: 1) }
        XCTAssertEqual(render(stream, frames: 1_000, channels: 1)[0][0], 0.5)
        // Having run dry, it waits again rather than playing each late packet.
        sample.withUnsafeBytes { _ = stream.push($0, sampleRate: 48_000, channels: 1) }
        XCTAssertEqual(render(stream, frames: 1_000, channels: 1)[0][0], 0)
        // That packet came right after the ring ran dry - late, not a new
        // sound - so the next wait is one step longer.
        let primed = PCMAudioStream.primingFrames + PCMAudioStream.primingStepFrames
        let short = [Int16](repeating: 8_192, count: primed - 2)
        short.withUnsafeBytes { _ = stream.push($0, sampleRate: 48_000, channels: 1) }
        XCTAssertEqual(render(stream, frames: 1, channels: 1)[0][0], 0)
        let full = [Int16](repeating: 8_192, count: 2)
        full.withUnsafeBytes { _ = stream.push($0, sampleRate: 48_000, channels: 1) }
        XCTAssertEqual(render(stream, frames: 2, channels: 1)[0], [0.5, 0.25])
    }

    func testOnlyLatePacketsLengthenThePriming() {
        let stream = PCMAudioStream()
        // In render-sized calls: one call renders at most 4,096 frames.
        func play(_ frames: Int) {
            for start in stride(from: 0, to: frames, by: 1_000) {
                _ = render(stream, frames: min(1_000, frames - start), channels: 1)
            }
        }
        func push(_ count: Int) {
            let samples = [Int16](repeating: 8_192, count: count)
            samples.withUnsafeBytes { _ = stream.push($0, sampleRate: 48_000, channels: 1) }
        }
        push(PCMAudioStream.primingFrames)
        play(PCMAudioStream.primingFrames + 1)
        // The sound ended: a long silence before the next one.
        play(PCMAudioStream.lateGapFrames)
        push(PCMAudioStream.primingFrames)
        XCTAssertEqual(render(stream, frames: 1, channels: 1)[0][0], 0.25,
                       "the end of a sound keeps the short wait")
        // Steps up to the cap, however late the packets keep coming.
        for _ in 0..<10 {
            play(PCMAudioStream.maximumPrimingFrames + 1)
            push(1)
            _ = render(stream, frames: 1, channels: 1)
        }
        play(PCMAudioStream.maximumPrimingFrames + 1)
        push(PCMAudioStream.maximumPrimingFrames)
        XCTAssertEqual(render(stream, frames: 1, channels: 1)[0][0], 0.25)
    }

    // MARK: - Clipboard

    private func connectedModel(
        policy: ClipboardPolicy = .bidirectional
    ) async throws -> (SessionWorkspaceModel, FakeRemoteSession) {
        let environment = AppEnvironment(
            store: InMemoryProfileStore(),
            credentials: InMemoryCredentialRepository(),
            trust: InMemoryTrustRepository(),
            factories: SessionFactoryRegistry(factories: [FakeSessionFactory()])
        )
        await environment.start()
        var configuration = RDPConfiguration()
        configuration.clipboardPolicy = .explicit(policy)
        await environment.save(ConnectionProfile(
            displayName: "desk",
            endpoint: RemoteEndpoint(host: "desk.example", port: 3389),
            configuration: .rdp(configuration)
        ), password: nil)
        let profile = try XCTUnwrap(environment.profiles.first)
        await environment.connect(to: profile)
        let model = try XCTUnwrap(environment.runningSession(for: profile))
        let found = await environment.sessions.session(for: model.id)
        let fake = try XCTUnwrap(found as? FakeRemoteSession)
        // Keep the environment alive for the test's duration.
        retained = environment
        return (model, fake)
    }

    private var retained: AppEnvironment?

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testARemoteCopyIsOfferedAndFetchedOnRequest() async throws {
        let (model, fake) = try await connectedModel()
        XCTAssertFalse(model.canReceiveClipboard)
        await fake.simulateRemoteCopy("リモートの\nテキスト")
        await waitUntil { model.remoteHasText }
        XCTAssertTrue(model.canReceiveClipboard)
        let text = await model.copyRemoteToDevice()
        XCTAssertEqual(text, "リモートの\nテキスト")
        XCTAssertNotNil(model.clipboardMessage)
        XCTAssertFalse(model.clipboardMessage?.contains("リモートの") ?? true,
                       "the toast never repeats clipboard content")
    }

    func testPastingOffersTheTextAndClosesTheMenu() async throws {
        let (model, fake) = try await connectedModel()
        model.isMenuPresented = true
        await model.pasteToRemote("こんにちは")
        let offered = await fake.offeredTexts
        XCTAssertEqual(offered, ["こんにちは"])
        XCTAssertFalse(model.isMenuPresented)
    }

    func testTextJustReceivedFromTheRemoteIsNotOfferedBack() async throws {
        let (model, fake) = try await connectedModel()
        await fake.simulateRemoteCopy("same")
        await waitUntil { model.remoteHasText }
        _ = await model.copyRemoteToDevice()
        await model.pasteToRemote("same")
        let offered = await fake.offeredTexts
        XCTAssertEqual(offered, [], "the remote already holds it; no reflection")
    }

    func testThePolicyDecidesTheDirection() async throws {
        let (model, fake) = try await connectedModel(policy: .receiveOnly)
        XCTAssertFalse(model.canSendClipboard)
        await model.pasteToRemote("blocked")
        let offered = await fake.offeredTexts
        XCTAssertEqual(offered, [])
    }
}
