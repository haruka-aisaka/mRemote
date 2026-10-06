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
        // Two stereo frames: (16384, -32768), (0, 32767).
        let samples: [Int16] = [16_384, -32_768, 0, 32_767]
        samples.withUnsafeBytes {
            XCTAssertTrue(stream.push($0, sampleRate: 48_000, channels: 2))
        }
        XCTAssertEqual(stream.format, .init(sampleRate: 48_000, channels: 2))
        let output = render(stream, frames: 3, channels: 2)
        XCTAssertEqual(output[0], [0.5, 0, 0])
        XCTAssertEqual(output[1][0], -1)
        XCTAssertEqual(output[1][1], 32_767.0 / 32_768.0, accuracy: 1e-6)
        XCTAssertEqual(output[1][2], 0, "an underrun plays silence, not stale samples")
    }

    func testAFullRingDropsWholePacketsAndADiscardEmptiesIt() {
        let stream = PCMAudioStream()
        let packet = [UInt8](repeating: 1, count: PCMAudioStream.capacityBytes / 2 + 4)
        packet.withUnsafeBytes {
            XCTAssertTrue(stream.push($0, sampleRate: 44_100, channels: 1))
            XCTAssertFalse(stream.push($0, sampleRate: 44_100, channels: 1))
        }
        XCTAssertEqual(stream.droppedPackets, 1)
        stream.discardBacklog()
        XCTAssertEqual(render(stream, frames: 4, channels: 1)[0], [0, 0, 0, 0])
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
