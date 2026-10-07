import AppleAdapters
import Darwin
import Foundation
import RDPProtocol
import SessionCore

/// A password on its way to `mr_rdp_session_create`, in storage that can
/// actually be erased.
///
/// A Swift `String`'s bytes cannot be zeroed, and the bridge copies and clears
/// its own copy on every path, so the app's copy is the only one left to
/// account for. It lives for exactly one create call.
final class SecureBytes: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8]

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return bytes.isEmpty
    }

    /// The span is borrowed for the duration of `body` only, which is exactly
    /// the contract `mr_rdp_config` documents for its credential fields.
    func withUnsafeSpan<T>(_ body: (UnsafePointer<CChar>?, Int) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return body(nil, 0) }
            return base.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                body($0, buffer.count)
            }
        }
    }

    func clear() {
        lock.lock()
        bytes.withUnsafeMutableBytes { raw in
            guard let address = raw.baseAddress, !raw.isEmpty else { return }
            _ = memset_s(address, raw.count, 0, raw.count)
        }
        bytes.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    deinit { clear() }
}

/// What the connect path needs that the profile does not carry.
struct RDPNativeConnection: Sendable {
    let host: String
    let port: UInt16
    let username: String
    let domain: String
    let password: SecureBytes
    let desktopWidth: UInt32
    let desktopHeight: UInt32
    let keyboardProfile: mr_rdp_keyboard_profile
    let channelFlags: mr_rdp_channel_flags
    let displayScale: RemoteDisplayScale
}

/// One already-classified event from the native session, delivered in order.
enum RDPNativeEvent: Sendable {
    case phase(RDPBridgePhase, generation: UInt64)
    case failure(RDPBridgeStatus, nativeCode: Int32, generation: UInt64)
    case channel(RDPBridgeChannel, isConnected: Bool)
    /// The certificate needs the user. Trust evaluation already ran and said
    /// so; everything the review sheet shows is in here.
    case certificateChallenge(RDPCertificateReview)
    /// The certificate was settled without asking. Carried for the log and so
    /// the session can record an approval it did not have to raise.
    case certificateSettled(accepted: Bool, detail: String)
    case displayResized(width: UInt32, height: UInt32)
    case clipboardRemoteFormats(hasText: Bool)
    case clipboardOffer(id: UInt64, stage: RDPClipboardOfferStage, succeeded: Bool)
    /// The remote text, already decoded; nil when the request failed.
    case clipboardText(requestID: UInt64, text: String?, status: RDPBridgeStatus)
    /// `mr_rdp_session_run` returned and the handle has been destroyed. This,
    /// not a backend phase, is when the session may call itself disconnected.
    case finished(run: RDPBridgeStatus, destroy: RDPBridgeStatus?)
}

enum RDPClipboardOfferStage: Sendable {
    case accepted
    case delivered
    case failed
}

/// A certificate the user has to look at, plus the identity the bridge needs
/// back to unblock its worker.
struct RDPCertificateReview: Sendable {
    let bridgeGeneration: UInt64
    let bridgeChallengeID: UInt64
    let challenge: CertificateChallenge
    let evidence: String
}

/// Owns the C session: creates it, runs it on its own thread, converts its
/// callbacks and lets the actor above call into it safely.
///
/// Nothing here is an actor. The bridge calls back on its own run thread and
/// the trust evaluation runs on a queue of its own; both feed one ordered
/// `AsyncStream` that the session actor consumes, which is what keeps the
/// order of `connecting` -> `awaitingCertificate` -> `connected` intact.
/// Independent `Task`s per callback would not.
final class RDPNativeSession: @unchecked Sendable {
    private let worker: DispatchQueue
    private let context: RDPNativeCallbackContext
    private let generation: UInt64
    private var didStart = false
    private let startLock = NSLock()

    let events: AsyncStream<RDPNativeEvent>

    init(
        generation: UInt64,
        endpoint: RemoteEndpoint,
        trust: any TrustRepository,
        logger: RDPSessionLogger,
        frameStore: LatestDesktopFrameStore,
        cursorStore: RemoteCursorStore,
        audioStream: PCMAudioStream
    ) {
        self.generation = generation
        worker = DispatchQueue(
            label: "com.mikuta0407.mRemote.rdp-session.\(generation)",
            qos: .userInitiated
        )
        var continuation: AsyncStream<RDPNativeEvent>.Continuation!
        // Unbounded on purpose: these are lifecycle events, not frames. Losing
        // a state change or a challenge would leave the UI describing a
        // connection that no longer exists, and the rate is bounded by the
        // handshake rather than by the server's frame rate.
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        context = RDPNativeCallbackContext(
            endpoint: endpoint,
            trust: trust,
            logger: logger,
            frameStore: frameStore,
            cursorStore: cursorStore,
            audioStream: audioStream,
            continuation: continuation
        )
    }

    /// Creates and runs the session on its own thread. Returns immediately;
    /// everything after this arrives through `events`.
    func start(_ connection: RDPNativeConnection) {
        startLock.lock()
        precondition(!didStart, "a native session runs at most once")
        didStart = true
        startLock.unlock()

        let generation = generation
        let context = context
        worker.async {
            let created = Self.create(
                connection: connection,
                generation: generation,
                context: context
            )
            // The bridge has deep-copied or refused the credential spans by
            // now, so the app's copy has no reason to exist any longer.
            connection.password.clear()

            guard created.status == mr_rdp_status(MR_RDP_STATUS_OK),
                  let session = created.session else {
                context.finish(
                    run: RDPBridgeStatus(rawValue: created.status) ?? .invalidState,
                    destroy: nil
                )
                return
            }

            context.install(session)
            let run = mr_rdp_session_run(session)
            // docs/architecture.md section 5.2: run returning is the stop
            // barrier, and only after destroy has drained the in-flight calls
            // may anything above treat the session as gone.
            let destroy = context.destroy()
            context.finish(
                run: RDPBridgeStatus(rawValue: run) ?? .invalidState,
                destroy: destroy.flatMap { RDPBridgeStatus(rawValue: $0) }
            )
        }
    }

    func requestStop() {
        context.requestStop()
    }

    func respondToCertificate(
        generation: UInt64,
        challengeID: UInt64,
        decision: mr_rdp_certificate_decision
    ) {
        context.respondCertificate(
            generation: generation,
            challengeID: challengeID,
            decision: decision
        )
    }

    func cancelCertificate(generation: UInt64, challengeID: UInt64) {
        context.cancelChallenge(generation: generation, challengeID: challengeID)
    }

    /// Enqueues one input event. Non-blocking: the bridge's own bounded queue
    /// absorbs the burst and its worker drains it, so these are safe to call
    /// straight from a UIKit event handler.
    func sendPointer(_ event: inout mr_rdp_pointer_event) {
        context.sendPointer(&event)
    }

    func sendKey(_ event: inout mr_rdp_key_event) {
        context.sendKey(&event)
    }

    func requestDisplayResize(
        requestID: UInt64,
        width: UInt32,
        height: UInt32,
        scale: RemoteDisplayScale
    ) -> Bool {
        context.requestDisplayResize(requestID: requestID, width: width, height: height, scale: scale)
    }

    /// Remembered and replayed once the handle exists, so a session focused
    /// before its worker created the C session still starts audible.
    func setAudioFocused(_ focused: Bool) {
        context.setAudioFocused(focused)
    }

    func sendUnicode(_ codeUnit: UInt16) {
        context.sendUnicode(codeUnit)
    }

    func offerClipboardText(offerID: UInt64, utf16le: Data) -> RDPBridgeStatus {
        context.offerClipboardText(offerID: offerID, utf16le: utf16le)
    }

    func requestClipboardText(requestID: UInt64) -> RDPBridgeStatus {
        context.requestClipboardText(requestID: requestID)
    }

    private static func create(
        connection: RDPNativeConnection,
        generation: UInt64,
        context: RDPNativeCallbackContext
    ) -> (status: mr_rdp_status, session: OpaquePointer?) {
        var callbacks = mr_rdp_callbacks()
        mr_rdp_callbacks_init(&callbacks)
        callbacks.on_state_changed = rdpStateCallback
        callbacks.on_certificate_challenge = rdpCertificateCallback
        callbacks.on_error = rdpErrorCallback
        callbacks.on_desktop_frame = rdpDesktopFrameCallback
        callbacks.on_channel_event = rdpChannelCallback
        callbacks.on_clipboard_probe_event = nil
        callbacks.on_display_resize_event = rdpDisplayResizeCallback
        callbacks.on_cursor = rdpCursorCallback
        callbacks.on_audio = rdpAudioCallback
        callbacks.on_clipboard_remote_formats = rdpClipboardRemoteFormatsCallback
        callbacks.on_clipboard_offer = rdpClipboardOfferCallback
        callbacks.on_clipboard_text = rdpClipboardTextCallback

        var config = mr_rdp_config()
        mr_rdp_config_init(&config)
        config.generation = generation
        config.port = connection.port
        config.desktop_width = connection.desktopWidth
        config.desktop_height = connection.desktopHeight
        config.keyboard_profile = connection.keyboardProfile
        config.channel_flags = connection.channelFlags
        config.desktop_scale_factor = UInt32(connection.displayScale.desktopPercent)
        config.device_scale_factor = UInt32(connection.displayScale.devicePercent)
        config.username_length = connection.username.utf8.count
        config.domain_length = connection.domain.utf8.count

        let opaque = Unmanaged.passUnretained(context).toOpaque()
        var session: OpaquePointer?
        let status = connection.host.withCString { host in
            connection.username.withCString { username in
                connection.password.withUnsafeSpan { password, passwordLength in
                    config.hostname = host
                    config.username = username
                    config.password = password
                    config.password_length = passwordLength
                    guard !connection.domain.isEmpty else {
                        config.domain = nil
                        config.domain_length = 0
                        return mr_rdp_session_create(&config, &callbacks, opaque, &session)
                    }
                    return connection.domain.withCString { domain in
                        config.domain = domain
                        return mr_rdp_session_create(&config, &callbacks, opaque, &session)
                    }
                }
            }
        }
        return (status, session)
    }
}

/// The bridge-facing side: the call gate, the frame store and the trust
/// evaluation that answers a certificate challenge without blocking the
/// callback thread.
final class RDPNativeCallbackContext: @unchecked Sendable {
    private let calls = RDPNativeCallGate()
    private let continuation: AsyncStream<RDPNativeEvent>.Continuation
    private let trustQueue = DispatchQueue(
        label: "com.mikuta0407.mRemote.certificate-trust",
        qos: .userInitiated
    )
    private let endpoint: RemoteEndpoint
    private let trust: any TrustRepository
    private let logger: RDPSessionLogger
    /// Owned by the session actor and shared across reconnects, so a surface
    /// that is already attached keeps drawing into the same store when the
    /// connection comes back.
    private let frameStore: LatestDesktopFrameStore
    private let cursorStore: RemoteCursorStore
    let audioStream: PCMAudioStream
    private let audioFocusLock = NSLock()
    private var audioFocused = false

    init(
        endpoint: RemoteEndpoint,
        trust: any TrustRepository,
        logger: RDPSessionLogger,
        frameStore: LatestDesktopFrameStore,
        cursorStore: RemoteCursorStore,
        audioStream: PCMAudioStream,
        continuation: AsyncStream<RDPNativeEvent>.Continuation
    ) {
        self.endpoint = endpoint
        self.trust = trust
        self.logger = logger
        self.frameStore = frameStore
        self.cursorStore = cursorStore
        self.audioStream = audioStream
        self.continuation = continuation
    }

    func install(_ session: OpaquePointer) {
        calls.install(session)
        audioFocusLock.lock()
        let focused = audioFocused
        audioFocusLock.unlock()
        _ = calls.setAudioFocused(focused)
    }

    func setAudioFocused(_ focused: Bool) {
        audioFocusLock.lock()
        audioFocused = focused
        audioFocusLock.unlock()
        _ = calls.setAudioFocused(focused)
    }

    func sendUnicode(_ codeUnit: UInt16) {
        guard codeUnit != 0 else { return }
        var event = mr_rdp_unicode_event()
        mr_rdp_unicode_event_init(&event)
        event.code_unit = codeUnit
        _ = calls.sendUnicode(&event)
    }

    func offerClipboardText(offerID: UInt64, utf16le: Data) -> RDPBridgeStatus {
        utf16le.withUnsafeBytes { bytes in
            var offer = mr_rdp_clipboard_offer()
            mr_rdp_clipboard_offer_init(&offer)
            offer.offer_id = offerID
            offer.utf16le_bytes = bytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
            offer.utf16le_byte_count = bytes.count
            return calls.offerClipboardText(&offer).flatMap(RDPBridgeStatus.init(rawValue:))
                ?? .invalidState
        }
    }

    func requestClipboardText(requestID: UInt64) -> RDPBridgeStatus {
        calls.requestClipboardText(requestID: requestID).flatMap(RDPBridgeStatus.init(rawValue:))
            ?? .invalidState
    }

    func receiveClipboardRemoteFormats(hasText: Bool) {
        continuation.yield(.clipboardRemoteFormats(hasText: hasText))
    }

    func receiveClipboardOffer(id: UInt64, stage: RDPClipboardOfferStage, succeeded: Bool) {
        continuation.yield(.clipboardOffer(id: id, stage: stage, succeeded: succeeded))
    }

    func receiveClipboardText(requestID: UInt64, text: String?, status: RDPBridgeStatus) {
        continuation.yield(.clipboardText(requestID: requestID, text: text, status: status))
    }
    func requestStop() { calls.requestStop() }
    func destroy() -> mr_rdp_status? { calls.destroy() }

    func finish(run: RDPBridgeStatus, destroy: RDPBridgeStatus?) {
        continuation.yield(.finished(run: run, destroy: destroy))
        continuation.finish()
    }

    func respondCertificate(
        generation: UInt64,
        challengeID: UInt64,
        decision: mr_rdp_certificate_decision
    ) {
        _ = calls.respondCertificate(
            generation: generation,
            challengeID: challengeID,
            decision: decision
        )
    }

    func cancelChallenge(generation: UInt64, challengeID: UInt64) {
        _ = calls.cancelChallenge(generation: generation, challengeID: challengeID)
    }

    func sendPointer(_ event: inout mr_rdp_pointer_event) {
        _ = calls.sendPointer(&event)
    }

    func sendKey(_ event: inout mr_rdp_key_event) {
        _ = calls.sendKey(&event)
    }

    func requestDisplayResize(
        requestID: UInt64,
        width: UInt32,
        height: UInt32,
        scale: RemoteDisplayScale
    ) -> Bool {
        var request = mr_rdp_display_resize_request()
        mr_rdp_display_resize_request_init(&request)
        request.request_id = requestID
        request.width = width
        request.height = height
        request.desktop_scale_factor = UInt32(scale.desktopPercent)
        request.device_scale_factor = UInt32(scale.devicePercent)
        return calls.requestDisplayResize(&request) == mr_rdp_status(MR_RDP_STATUS_OK)
    }

    // MARK: - Callback entry points

    func receivePhase(_ raw: mr_rdp_session_state, generation: UInt64) {
        guard let phase = RDPBridgePhase(rawValue: raw) else { return }
        continuation.yield(.phase(phase, generation: generation))
    }

    func receiveError(status: mr_rdp_status, nativeCode: Int32, generation: UInt64) {
        let mapped = RDPBridgeStatus(rawValue: status) ?? .backend
        continuation.yield(.failure(mapped, nativeCode: nativeCode, generation: generation))
    }

    func receiveChannel(_ channel: RDPBridgeChannel, isConnected: Bool) {
        continuation.yield(.channel(channel, isConnected: isConnected))
    }

    func receiveDisplayResize(width: UInt32, height: UInt32) {
        continuation.yield(.displayResized(width: width, height: height))
    }

    func receiveFrame(_ frame: DesktopFrame) {
        // Straight to the store: docs/architecture.md keeps frames off the
        // control plane, so this never touches the session actor.
        frameStore.submit(frame)
    }

    func receiveCursor(_ cursor: RemoteCursor) {
        cursorStore.submit(cursor)
    }

    func rejectMalformedCertificate(generation: UInt64, challengeID: UInt64) {
        respondCertificate(
            generation: generation,
            challengeID: challengeID,
            decision: mr_rdp_certificate_decision(MR_RDP_CERTIFICATE_REJECT)
        )
        logger.certificate("rejected a malformed certificate callback")
        continuation.yield(.certificateSettled(
            accepted: false,
            detail: "malformed certificate callback"
        ))
    }

    /// Leaves the callback thread before evaluating. The DER has already been
    /// copied; the bridge is waiting on its own generation-bound condition and
    /// starts its timeout only once the callback returns.
    func receiveCertificate(_ snapshot: RDPCertificateSnapshot) {
        trustQueue.async { [self] in evaluate(snapshot) }
    }

    private func evaluate(_ snapshot: RDPCertificateSnapshot) {
        let presented = PresentedServerCertificate(
            sessionGeneration: snapshot.generation,
            hostname: snapshot.hostname,
            port: snapshot.port,
            certificateChainDER: snapshot.chainDER
        )
        let evaluation: ServerTrustEvaluation
        do {
            evaluation = try ServerTrustEvaluator().evaluate(presented)
        } catch {
            logger.certificate("evaluation failed: \(error)")
            settle(snapshot, accepted: false, detail: "証明書を評価できません")
            return
        }
        logger.certificate(evaluation.evidenceDescription)

        let leafSHA256 = evaluation.certificateFingerprints.leafSHA256
        let pin: CertificatePinState
        switch (try? trust.decision(
            host: endpoint.host,
            port: endpoint.port,
            leafSHA256: leafSHA256
        )) ?? .noRecord {
        case .noRecord: pin = .none
        case .matches: pin = .matches
        case .fingerprintChanged(let record):
            pin = .changed(previousLeafSHA256: record.leafSHA256)
        }

        switch CertificateReviewPolicy.verdict(evaluation: evaluation, pin: pin) {
        case .accept(let reason):
            let decision = reason == .systemTrust
                ? MR_RDP_CERTIFICATE_ACCEPT_SYSTEM_TRUST
                : MR_RDP_CERTIFICATE_ACCEPT_PIN
            respondCertificate(
                generation: snapshot.generation,
                challengeID: snapshot.challengeID,
                decision: mr_rdp_certificate_decision(decision)
            )
            continuation.yield(.certificateSettled(
                accepted: true,
                detail: reason == .systemTrust ? "system trust" : "stored approval"
            ))

        case .reject(let reason):
            settle(snapshot, accepted: false, detail: reason)

        case .ask(let disposition):
            let summary = CertificateSummaryParser.summary(fromLeafDER: snapshot.chainDER[0])
            let challenge = CertificateChallenge(
                generation: SessionGeneration(snapshot.generation),
                host: endpoint.host,
                port: endpoint.port,
                leafSHA256: leafSHA256,
                chainSHA256: evaluation.certificateFingerprints.chainSHA256
                    .joined(separator: ","),
                subject: summary?.subject ?? "(読み取れません)",
                issuer: summary?.issuer ?? "(読み取れません)",
                // A certificate whose validity cannot be parsed still has to
                // be reviewable; the dates are shown as unknown rather than
                // invented, and the fingerprint is the identity either way.
                notBefore: summary?.notBefore ?? .distantPast,
                notAfter: summary?.notAfter ?? .distantFuture,
                disposition: disposition
            )
            continuation.yield(.certificateChallenge(RDPCertificateReview(
                bridgeGeneration: snapshot.generation,
                bridgeChallengeID: snapshot.challengeID,
                challenge: challenge,
                evidence: evaluation.evidenceDescription
            )))
        }
    }

    private func settle(_ snapshot: RDPCertificateSnapshot, accepted: Bool, detail: String) {
        respondCertificate(
            generation: snapshot.generation,
            challengeID: snapshot.challengeID,
            decision: mr_rdp_certificate_decision(MR_RDP_CERTIFICATE_REJECT)
        )
        continuation.yield(.certificateSettled(accepted: accepted, detail: detail))
    }
}

/// A certificate callback copied into app-owned memory.
///
/// The bridge's views expire when the callback returns, so every byte is
/// copied here with `Data(bytes:count:)` and nothing borrowed escapes.
struct RDPCertificateSnapshot: @unchecked Sendable {
    /// The header expresses these as parenthesised macro arithmetic, which
    /// does not reach Swift, so they are restated. They are re-checked rather
    /// than trusted: the bridge already enforces them, and neither side may be
    /// the only bound on a chain that arrived over the network.
    static let maximumChainCount = 16
    static let maximumCertificateBytes = 1_024 * 1_024
    static let maximumChainBytes = 4 * 1_024 * 1_024

    let generation: UInt64
    let challengeID: UInt64
    let hostname: String
    let port: UInt16
    let chainDER: [Data]

    init?(copying pointer: UnsafePointer<mr_rdp_certificate_challenge>) {
        let native = pointer.pointee
        guard native.struct_size >= UInt32(MemoryLayout<mr_rdp_certificate_challenge>.size),
              native.generation != 0,
              native.challenge_id != 0,
              native.hostname_length > 0,
              native.hostname_length <= 253,
              native.chain_count > 0,
              native.chain_count <= Self.maximumChainCount,
              let hostnameBytes = native.hostname,
              let blobs = native.chain else {
            return nil
        }
        let hostnameData = Data(bytes: hostnameBytes, count: native.hostname_length)
        guard let hostname = String(data: hostnameData, encoding: .utf8),
              !hostname.contains("\0") else {
            return nil
        }

        var total = 0
        var chain: [Data] = []
        chain.reserveCapacity(native.chain_count)
        for index in 0..<native.chain_count {
            let blob = blobs[index]
            guard blob.length > 0,
                  blob.length <= Self.maximumCertificateBytes,
                  let bytes = blob.bytes else {
                return nil
            }
            let (running, overflow) = total.addingReportingOverflow(blob.length)
            guard !overflow, running <= Self.maximumChainBytes else {
                return nil
            }
            total = running
            chain.append(Data(bytes: bytes, count: blob.length))
        }

        generation = native.generation
        challengeID = native.challenge_id
        self.hostname = hostname
        port = native.port
        chainDER = chain
    }
}

/// Copies one desktop frame out of the backend's view.
///
/// Deliberately `Data(bytes:count:)` and not a no-copy wrapper: the backend
/// owns those pixels only until the callback returns, and the renderer reads
/// them long afterwards.
func rdpDesktopFrame(copying pointer: UnsafePointer<mr_rdp_desktop_frame>) -> DesktopFrame? {
    let frame = pointer.pointee
    guard frame.struct_size >= UInt32(MemoryLayout<mr_rdp_desktop_frame>.size),
          frame.generation != 0,
          frame.surface_generation != 0,
          frame.frame_id != 0,
          frame.dirty_rect_count > 0,
          let bytes = frame.bytes,
          let nativeRects = frame.dirty_rects else {
        return nil
    }

    var rectangles: [PixelRect] = []
    rectangles.reserveCapacity(frame.dirty_rect_count)
    for index in 0..<frame.dirty_rect_count {
        let rectangle = nativeRects[index]
        rectangles.append(PixelRect(
            x: Int(rectangle.x),
            y: Int(rectangle.y),
            width: Int(rectangle.width),
            height: Int(rectangle.height)
        ))
    }

    // Validate before touching the buffer: this is the second bounds check on
    // the frame, and it is the one that decides how many bytes are read.
    guard let validated = try? DesktopFrameValidator.validate(
        width: Int(frame.width),
        height: Int(frame.height),
        bytesPerRow: Int(frame.stride),
        byteCount: frame.length,
        dirtyRectangles: rectangles
    ) else {
        return nil
    }

    return DesktopFrame(
        width: Int(frame.width),
        height: Int(frame.height),
        bytesPerRow: Int(frame.stride),
        pixels: Data(bytes: bytes, count: validated.requiredBytes),
        dirtyRectangles: rectangles,
        generation: SessionGeneration(frame.generation),
        surfaceGeneration: frame.surface_generation,
        frameID: frame.frame_id
    )
}

// MARK: - C callbacks

private func callbackContext(
    _ opaque: UnsafeMutableRawPointer?
) -> RDPNativeCallbackContext? {
    guard let opaque else { return nil }
    return Unmanaged<RDPNativeCallbackContext>.fromOpaque(opaque).takeUnretainedValue()
}

private func rdpStateCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_state_event>?
) {
    guard let context = callbackContext(opaque), let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_state_event>.size)
    else { return }
    let event = eventPointer.pointee
    context.receivePhase(event.state, generation: event.generation)
}

private func rdpErrorCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_error_event>?
) {
    guard let context = callbackContext(opaque), let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_error_event>.size)
    else { return }
    let event = eventPointer.pointee
    context.receiveError(
        status: event.status,
        nativeCode: event.native_code,
        generation: event.generation
    )
}

private func rdpCertificateCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ challengePointer: UnsafePointer<mr_rdp_certificate_challenge>?
) {
    guard let context = callbackContext(opaque), let challengePointer else { return }
    // Read the response identity before validating, so a malformed challenge
    // can still be answered and its worker released.
    let generation = challengePointer.pointee.generation
    let challengeID = challengePointer.pointee.challenge_id
    guard let snapshot = RDPCertificateSnapshot(copying: challengePointer) else {
        context.rejectMalformedCertificate(generation: generation, challengeID: challengeID)
        return
    }
    context.receiveCertificate(snapshot)
}

private func rdpDesktopFrameCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ framePointer: UnsafePointer<mr_rdp_desktop_frame>?
) {
    guard let context = callbackContext(opaque), let framePointer,
          let frame = rdpDesktopFrame(copying: framePointer) else { return }
    context.receiveFrame(frame)
}

private func rdpChannelCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_channel_event>?
) {
    guard let context = callbackContext(opaque), let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_channel_event>.size)
    else { return }
    let event = eventPointer.pointee
    guard event.generation != 0,
          event.sequence != 0,
          let channel = RDPBridgeChannel(rawValue: event.channel)
    else { return }
    context.receiveChannel(
        channel,
        isConnected: event.transition == mr_rdp_channel_transition(MR_RDP_CHANNEL_CONNECTED)
    )
}

private func rdpDisplayResizeCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_display_resize_event>?
) {
    guard let context = callbackContext(opaque), let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(
              MemoryLayout<mr_rdp_display_resize_event>.size
          )
    else { return }
    let event = eventPointer.pointee
    guard event.status == mr_rdp_status(MR_RDP_STATUS_OK),
          event.width >= UInt32(MR_RDP_MIN_DESKTOP_DIMENSION),
          event.width <= UInt32(MR_RDP_MAX_DESKTOP_DIMENSION),
          event.height >= UInt32(MR_RDP_MIN_DESKTOP_DIMENSION),
          event.height <= UInt32(MR_RDP_MAX_DESKTOP_DIMENSION)
    else { return }
    context.receiveDisplayResize(width: event.width, height: event.height)
}

private func rdpCursorCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_cursor_event>?
) {
    guard let context = callbackContext(opaque), let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_cursor_event>.size)
    else { return }
    let event = eventPointer.pointee
    if event.kind == mr_rdp_cursor_kind(MR_RDP_CURSOR_HIDDEN) {
        context.receiveCursor(.hidden)
    } else if event.kind == mr_rdp_cursor_kind(MR_RDP_CURSOR_SHAPE) {
        guard let bytes = event.bytes else { return }
        // Copied and premultiplied here: the bridge's view ends with the
        // callback.
        let image = RemoteCursorImage(
            straightBGRA: UnsafeRawBufferPointer(start: bytes, count: event.length),
            width: Int(event.width),
            height: Int(event.height),
            sourceBytesPerRow: Int(event.stride),
            hotspotX: Int(event.hotspot_x),
            hotspotY: Int(event.hotspot_y)
        )
        context.receiveCursor(image.map(RemoteCursor.shape) ?? .systemDefault)
    } else {
        context.receiveCursor(.systemDefault)
    }
}

private func rdpAudioCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ packetPointer: UnsafePointer<mr_rdp_audio_packet>?
) {
    guard let context = callbackContext(opaque), let packetPointer,
          packetPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_audio_packet>.size)
    else { return }
    let packet = packetPointer.pointee
    guard let bytes = packet.bytes, packet.bits_per_sample == 16,
          (1...2).contains(packet.channels) else { return }
    // Straight into the ring: audio, like frames, never touches the actor.
    context.audioStream.push(
        UnsafeRawBufferPointer(start: bytes, count: packet.length),
        sampleRate: Double(packet.samples_per_second),
        channels: Int(packet.channels)
    )
}

private func rdpClipboardRemoteFormatsCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_clipboard_remote_formats_event>?
) {
    guard let context = callbackContext(opaque), let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(
              MemoryLayout<mr_rdp_clipboard_remote_formats_event>.size
          )
    else { return }
    context.receiveClipboardRemoteFormats(hasText: eventPointer.pointee.has_text != 0)
}

private func rdpClipboardOfferCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_clipboard_offer_event>?
) {
    guard let context = callbackContext(opaque), let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_clipboard_offer_event>.size)
    else { return }
    let event = eventPointer.pointee
    let stage: RDPClipboardOfferStage
    if event.stage == mr_rdp_clipboard_offer_stage(MR_RDP_CLIPBOARD_OFFER_ACCEPTED) {
        stage = .accepted
    } else if event.stage == mr_rdp_clipboard_offer_stage(MR_RDP_CLIPBOARD_OFFER_DELIVERED) {
        stage = .delivered
    } else {
        stage = .failed
    }
    context.receiveClipboardOffer(
        id: event.offer_id,
        stage: stage,
        succeeded: event.status == mr_rdp_status(MR_RDP_STATUS_OK)
    )
}

private func rdpClipboardTextCallback(
    _ opaque: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_clipboard_text_event>?
) {
    guard let context = callbackContext(opaque), let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_clipboard_text_event>.size)
    else { return }
    let event = eventPointer.pointee
    let status = RDPBridgeStatus(rawValue: event.status) ?? .backend
    guard status == .ok else {
        context.receiveClipboardText(requestID: event.request_id, text: nil, status: status)
        return
    }
    // Copied and decoded here: the bridge's span ends with the callback.
    let data = event.utf16le_bytes.map { Data(bytes: $0, count: event.utf16le_byte_count) } ?? Data()
    context.receiveClipboardText(
        requestID: event.request_id,
        text: ClipboardTextCodec.decode(data),
        status: .ok
    )
}
