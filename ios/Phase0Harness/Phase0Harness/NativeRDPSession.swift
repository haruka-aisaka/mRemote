#if PHASE0_NATIVE
import CoreGraphics
import Darwin
import Foundation

struct NativeDesktopFrameSnapshot: @unchecked Sendable {
    let generation: UInt64
    let surfaceGeneration: UInt64
    let frameID: UInt64
    let update: BGRADesktopUpdate

    init?(copying pointer: UnsafePointer<mr_rdp_desktop_frame>) {
        let frame = pointer.pointee
        guard frame.struct_size >= UInt32(MemoryLayout<mr_rdp_desktop_frame>.size),
              frame.generation != 0,
              frame.surface_generation != 0,
              frame.frame_id != 0,
              frame.width > 0,
              frame.height > 0,
              frame.width <= 8_192,
              frame.height <= 8_192,
              frame.stride >= frame.width * 4,
              frame.dirty_rect_count > 0,
              frame.dirty_rect_count <= 512,
              let bytes = frame.bytes,
              let nativeRectangles = frame.dirty_rects else {
            return nil
        }

        let stride = Int(frame.stride)
        let height = Int(frame.height)
        let (requiredBytes, overflow) = stride.multipliedReportingOverflow(by: height)
        guard !overflow,
              requiredBytes <= 512 * 1_024 * 1_024,
              frame.length >= requiredBytes else {
            return nil
        }

        var rectangles: [CGRect] = []
        rectangles.reserveCapacity(frame.dirty_rect_count)
        for index in 0..<frame.dirty_rect_count {
            let rectangle = nativeRectangles[index]
            guard rectangle.width > 0,
                  rectangle.height > 0,
                  rectangle.x < frame.width,
                  rectangle.y < frame.height,
                  rectangle.width <= frame.width - rectangle.x,
                  rectangle.height <= frame.height - rectangle.y else {
                return nil
            }
            rectangles.append(CGRect(
                x: Int(rectangle.x),
                y: Int(rectangle.y),
                width: Int(rectangle.width),
                height: Int(rectangle.height)
            ))
        }

        // This is intentionally Data(bytes:count:), not a no-copy wrapper:
        // the backend's frame view expires when the C callback returns.
        let pixels = Data(bytes: bytes, count: requiredBytes)
        generation = frame.generation
        surfaceGeneration = frame.surface_generation
        frameID = frame.frame_id
        update = BGRADesktopUpdate(
            width: Int(frame.width),
            height: height,
            bytesPerRow: stride,
            pixels: pixels,
            dirtyRectangles: rectangles
        )
    }

    private init(
        generation: UInt64,
        surfaceGeneration: UInt64,
        frameID: UInt64,
        update: BGRADesktopUpdate
    ) {
        self.generation = generation
        self.surfaceGeneration = surfaceGeneration
        self.frameID = frameID
        self.update = update
    }

    func coalescingDamage(from pending: NativeDesktopFrameSnapshot) -> Self {
        let damage = LatestFrameDamageCoalescer.coalescedDamage(
            replacing: pending.damageEnvelope,
            with: damageEnvelope
        )
        return Self(
            generation: generation,
            surfaceGeneration: surfaceGeneration,
            frameID: frameID,
            update: BGRADesktopUpdate(
                width: update.width,
                height: update.height,
                bytesPerRow: update.bytesPerRow,
                pixels: update.pixels,
                dirtyRectangles: damage
            )
        )
    }

    func requiringFullDamage() -> Self {
        Self(
            generation: generation,
            surfaceGeneration: surfaceGeneration,
            frameID: frameID,
            update: BGRADesktopUpdate(
                width: update.width,
                height: update.height,
                bytesPerRow: update.bytesPerRow,
                pixels: update.pixels,
                dirtyRectangles: []
            )
        )
    }

    private var damageEnvelope: FrameDamageEnvelope {
        FrameDamageEnvelope(
            generation: generation,
            surfaceGeneration: surfaceGeneration,
            width: update.width,
            height: update.height,
            bytesPerRow: update.bytesPerRow,
            dirtyRectangles: update.dirtyRectangles
        )
    }
}

struct NativeCertificateReview: Equatable, Sendable {
    let generation: UInt64
    let hostname: String
    let port: UInt16
    let certificateFingerprints: ServerCertificateFingerprints
    let systemTrustSummary: String

    var leafSHA256: String { certificateFingerprints.leafSHA256 }
}

private struct NativeCertificateSnapshot: @unchecked Sendable {
    let generation: UInt64
    let challengeID: UInt64
    let challenge: ServerCertificateChallenge

    init?(copying pointer: UnsafePointer<mr_rdp_certificate_challenge>) {
        let native = pointer.pointee
        guard native.struct_size >= UInt32(MemoryLayout<mr_rdp_certificate_challenge>.size),
              native.generation != 0,
              native.challenge_id != 0,
              native.hostname_length > 0,
              native.hostname_length <= 253,
              native.chain_count > 0,
              native.chain_count <= 16,
              let hostnameBytes = native.hostname,
              let blobs = native.chain else {
            return nil
        }

        let hostnameData = Data(bytes: hostnameBytes, count: native.hostname_length)
        guard let hostname = String(data: hostnameData, encoding: .utf8),
              !hostname.contains("\0") else {
            return nil
        }

        var totalBytes = 0
        var chain: [Data] = []
        chain.reserveCapacity(native.chain_count)
        for index in 0..<native.chain_count {
            let blob = blobs[index]
            guard blob.length > 0,
                  blob.length <= 1_024 * 1_024,
                  let bytes = blob.bytes else {
                return nil
            }
            let (newTotal, overflow) = totalBytes.addingReportingOverflow(blob.length)
            guard !overflow, newTotal <= 4 * 1_024 * 1_024 else { return nil }
            totalBytes = newTotal
            // As with frames, the DER pointer must not escape this callback.
            chain.append(Data(bytes: bytes, count: blob.length))
        }

        generation = native.generation
        challengeID = native.challenge_id
        challenge = ServerCertificateChallenge(
            sessionGeneration: native.generation,
            hostname: hostname,
            port: native.port,
            certificateChainDER: chain
        )
    }
}

/// Bounds callback-to-MainActor ownership to one queued snapshot plus the one
/// currently being applied. Replacing `latest` immediately releases an older
/// full-frame Data instead of accumulating one Task/Data pair per callback.
private final class LatestNativeFrameMailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var latest: NativeDesktopFrameSnapshot?
    private var deliveryScheduled = false
    private let deliver: @MainActor @Sendable (NativeDesktopFrameSnapshot) -> Void

    init(
        deliver: @escaping @MainActor @Sendable (NativeDesktopFrameSnapshot) -> Void
    ) {
        self.deliver = deliver
    }

    func submit(_ frame: NativeDesktopFrameSnapshot) {
        lock.lock()
        if let pending = latest {
            latest = frame.coalescingDamage(from: pending)
        } else {
            latest = frame
        }
        let shouldSchedule = !deliveryScheduled
        deliveryScheduled = true
        lock.unlock()

        if shouldSchedule {
            Task { @MainActor [self] in deliverLatest() }
        }
    }

    @MainActor
    private func deliverLatest() {
        lock.lock()
        let frame = latest
        latest = nil
        if frame == nil { deliveryScheduled = false }
        lock.unlock()
        guard let frame else { return }

        deliver(frame)

        lock.lock()
        let hasAnotherFrame = latest != nil
        if !hasAnotherFrame { deliveryScheduled = false }
        lock.unlock()
        if hasAnotherFrame {
            Task { @MainActor [self] in
                await Task.yield()
                deliverLatest()
            }
        }
    }
}

private final class NativeSessionCallGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var session: OpaquePointer?
    private var callsInFlight = 0
    private var stopRequested = false
    private var destroying = false

    func install(_ session: OpaquePointer) {
        condition.lock()
        precondition(self.session == nil && !destroying)
        self.session = session
        let mustStop = stopRequested
        condition.unlock()
        if mustStop { _ = requestStop() }
    }

    func requestStop() -> mr_rdp_status? {
        condition.lock()
        stopRequested = true
        condition.unlock()
        return call { mr_rdp_session_request_stop($0) }
    }

    func respondCertificate(
        generation: UInt64,
        challengeID: UInt64,
        decision: mr_rdp_certificate_decision
    ) -> mr_rdp_status? {
        call {
            mr_rdp_session_respond_certificate(
                $0,
                generation,
                challengeID,
                decision
            )
        }
    }

    func sendKey(_ event: inout mr_rdp_key_event) -> mr_rdp_status? {
        call { mr_rdp_session_send_key($0, &event) }
    }

    func sendPointer(_ event: inout mr_rdp_pointer_event) -> mr_rdp_status? {
        call { mr_rdp_session_send_pointer($0, &event) }
    }

    func startClipboardProbe(_ probe: inout mr_rdp_clipboard_probe) -> mr_rdp_status? {
        call { mr_rdp_session_start_clipboard_probe($0, &probe) }
    }

    func requestDisplayResize(
        _ request: inout mr_rdp_display_resize_request
    ) -> mr_rdp_status? {
        call { mr_rdp_session_request_display_resize($0, &request) }
    }

    /// Stops new calls before destroy begins and drains calls that already
    /// acquired the pointer. The C bridge separately drains its backend calls.
    func destroy() -> mr_rdp_status? {
        condition.lock()
        destroying = true
        while callsInFlight > 0 { condition.wait() }
        let doomed = session
        session = nil
        condition.unlock()
        guard let doomed else { return nil }
        return mr_rdp_session_destroy(doomed)
    }

    private func call(
        _ body: (OpaquePointer) -> mr_rdp_status
    ) -> mr_rdp_status? {
        condition.lock()
        guard !destroying, let session else {
            condition.unlock()
            return nil
        }
        callsInFlight += 1
        condition.unlock()

        let result = body(session)

        condition.lock()
        callsInFlight -= 1
        condition.broadcast()
        condition.unlock()
        return result
    }
}

private final class NativeRDPCallbackContext: @unchecked Sendable {
    private let calls = NativeSessionCallGate()
    private let events = OrderedMainActorDeliveryQueue()
    private let trustQueue = DispatchQueue(
        label: "dev.mremote.phase0.certificate-trust",
        qos: .userInitiated
    )
    private let onStatus: @MainActor @Sendable (HarnessSessionStatus) -> Void
    private let frames: LatestNativeFrameMailbox
    private let onCertificate: @MainActor @Sendable (String) -> Void
    private let onChannel: @MainActor @Sendable (Phase0ChannelTelemetry) -> Void
    private let onClipboardProbe: @MainActor @Sendable (
        Phase0ClipboardProbeTelemetry
    ) -> Void
    private let onDisplayResize: @MainActor @Sendable (
        Phase0DisplayResizeTelemetry
    ) -> Void
    private let onUntrustedCertificate: @MainActor @Sendable (
        NativeCertificateReview,
        @escaping @Sendable (Bool) -> Void
    ) -> Void

    init(
        onStatus: @escaping @MainActor @Sendable (HarnessSessionStatus) -> Void,
        onFrame: @escaping @MainActor @Sendable (NativeDesktopFrameSnapshot) -> Void,
        onCertificate: @escaping @MainActor @Sendable (String) -> Void,
        onChannel: @escaping @MainActor @Sendable (Phase0ChannelTelemetry) -> Void,
        onClipboardProbe: @escaping @MainActor @Sendable (
            Phase0ClipboardProbeTelemetry
        ) -> Void,
        onDisplayResize: @escaping @MainActor @Sendable (
            Phase0DisplayResizeTelemetry
        ) -> Void,
        onUntrustedCertificate: @escaping @MainActor @Sendable (
            NativeCertificateReview,
            @escaping @Sendable (Bool) -> Void
        ) -> Void
    ) {
        self.onStatus = onStatus
        frames = LatestNativeFrameMailbox(deliver: onFrame)
        self.onCertificate = onCertificate
        self.onChannel = onChannel
        self.onClipboardProbe = onClipboardProbe
        self.onDisplayResize = onDisplayResize
        self.onUntrustedCertificate = onUntrustedCertificate
    }

    func install(_ session: OpaquePointer) {
        calls.install(session)
    }

    func requestStop() -> mr_rdp_status? {
        calls.requestStop()
    }

    func destroy() -> mr_rdp_status? {
        calls.destroy()
    }

    func sendKey(_ event: inout mr_rdp_key_event) -> mr_rdp_status? {
        calls.sendKey(&event)
    }

    func sendPointer(_ event: inout mr_rdp_pointer_event) -> mr_rdp_status? {
        calls.sendPointer(&event)
    }

    func startClipboardProbe(_ probe: inout mr_rdp_clipboard_probe) -> mr_rdp_status? {
        calls.startClipboardProbe(&probe)
    }

    func requestDisplayResize(
        _ request: inout mr_rdp_display_resize_request
    ) -> mr_rdp_status? {
        calls.requestDisplayResize(&request)
    }

    func receiveState(generation: UInt64, nativeState: mr_rdp_session_state) {
        let phase: HarnessSessionPhase
        switch nativeState {
        case mr_rdp_session_state(MR_RDP_SESSION_CREATED): phase = .idle
        case mr_rdp_session_state(MR_RDP_SESSION_CONNECTING): phase = .connecting
        case mr_rdp_session_state(MR_RDP_SESSION_AWAITING_CERTIFICATE):
            phase = .awaitingCertificate
        case mr_rdp_session_state(MR_RDP_SESSION_CONNECTED): phase = .connected
        case mr_rdp_session_state(MR_RDP_SESSION_STOPPING): phase = .stopping
        case mr_rdp_session_state(MR_RDP_SESSION_STOPPED): phase = .stopped
        default: phase = .failed
        }
        emitStatus(HarnessSessionStatus(
            generation: generation,
            phase: phase,
            statusCode: nil
        ))
    }

    func receiveError(generation: UInt64, status: mr_rdp_status) {
        emitStatus(HarnessSessionStatus(
            generation: generation,
            phase: .failed,
            statusCode: status
        ))
    }

    func receiveFrame(_ frame: NativeDesktopFrameSnapshot) {
        frames.submit(frame)
    }

    func receiveChannel(_ telemetry: Phase0ChannelTelemetry) {
        events.submit { @MainActor [onChannel] in onChannel(telemetry) }
    }

    func receiveClipboardProbe(_ telemetry: Phase0ClipboardProbeTelemetry) {
        events.submit { @MainActor [onClipboardProbe] in onClipboardProbe(telemetry) }
    }

    func receiveDisplayResize(_ telemetry: Phase0DisplayResizeTelemetry) {
        events.submit { @MainActor [onDisplayResize] in onDisplayResize(telemetry) }
    }

    func rejectMalformedCertificate(generation: UInt64, challengeID: UInt64) {
        let decision = mr_rdp_certificate_decision(MR_RDP_CERTIFICATE_REJECT)
        let response = calls.respondCertificate(
            generation: generation,
            challengeID: challengeID,
            decision: decision
        )
        emitCertificate("certificate callback rejected malformed snapshot response=\(response ?? -1)")
    }

    func receiveCertificate(_ snapshot: NativeCertificateSnapshot) {
        // DER has already been synchronously copied by the C callback. Trust
        // evaluation can now leave that callback thread while the bridge waits
        // for this generation/challenge-bound response.
        trustQueue.async { [self] in
            guard let copiedFingerprints = ServerCertificateFingerprints(
                certificateChainDER: snapshot.challenge.certificateChainDER
            ) else {
                let response = calls.respondCertificate(
                    generation: snapshot.generation,
                    challengeID: snapshot.challengeID,
                    decision: mr_rdp_certificate_decision(MR_RDP_CERTIFICATE_REJECT)
                )
                emitCertificate("certificate missing leaf response=\(response ?? -1)")
                return
            }
            let result: ServerTrustEvaluation
            do {
                result = try ServerTrustEvaluator().evaluate(snapshot.challenge)
            } catch {
                let response = calls.respondCertificate(
                    generation: snapshot.generation,
                    challengeID: snapshot.challengeID,
                    decision: mr_rdp_certificate_decision(MR_RDP_CERTIFICATE_REJECT)
                )
                emitCertificate(
                    "certificate \(RDPDiagnosticRedaction.endpoint(port: snapshot.challenge.port)) outcome=hard-reject \(copiedFingerprints) evaluation error=\(error) response=\(response ?? -1)"
                )
                return
            }

            if result.isTrusted {
                let response = calls.respondCertificate(
                    generation: snapshot.generation,
                    challengeID: snapshot.challengeID,
                    decision: mr_rdp_certificate_decision(
                        MR_RDP_CERTIFICATE_ACCEPT_SYSTEM_TRUST
                    )
                )
                emitCertificate(
                    "certificate \(RDPDiagnosticRedaction.endpoint(port: snapshot.challenge.port)) \(result.evidenceDescription) response=\(response ?? -1)"
                )
                return
            }

            guard result.permitsTrustOnce else {
                let response = calls.respondCertificate(
                    generation: snapshot.generation,
                    challengeID: snapshot.challengeID,
                    decision: mr_rdp_certificate_decision(MR_RDP_CERTIFICATE_REJECT)
                )
                emitCertificate(
                    "certificate \(RDPDiagnosticRedaction.endpoint(port: snapshot.challenge.port)) \(result.evidenceDescription) response=\(response ?? -1)"
                )
                return
            }

            let review = NativeCertificateReview(
                generation: snapshot.generation,
                hostname: snapshot.challenge.hostname,
                port: snapshot.challenge.port,
                certificateFingerprints: result.certificateFingerprints,
                systemTrustSummary: result.summary
            )
            emitCertificate(
                "certificate \(RDPDiagnosticRedaction.endpoint(port: snapshot.challenge.port)) \(result.evidenceDescription)"
            )
            events.submit { @MainActor [onUntrustedCertificate] in
                onUntrustedCertificate(review) { [self] trustOnce in
                    let response = calls.respondCertificate(
                        generation: snapshot.generation,
                        challengeID: snapshot.challengeID,
                        decision: mr_rdp_certificate_decision(
                            trustOnce
                                ? MR_RDP_CERTIFICATE_ACCEPT_USER_ONCE
                                : MR_RDP_CERTIFICATE_REJECT
                        )
                    )
                    emitCertificate(
                        "certificate \(RDPDiagnosticRedaction.endpoint(port: review.port)) decision=\(trustOnce ? "trust-once" : "reject") \(review.certificateFingerprints) response=\(response ?? -1)"
                    )
                }
            }
        }
    }

    private func emitStatus(_ status: HarnessSessionStatus) {
        events.submit { @MainActor [onStatus] in onStatus(status) }
    }

    private func emitCertificate(_ message: String) {
        events.submit { @MainActor [onCertificate] in onCertificate(message) }
    }
}

private func nativeRDPStateCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_state_event>?
) {
    guard let opaqueContext, let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_state_event>.size) else {
        return
    }
    let event = eventPointer.pointee
    let context = Unmanaged<NativeRDPCallbackContext>
        .fromOpaque(opaqueContext)
        .takeUnretainedValue()
    context.receiveState(generation: event.generation, nativeState: event.state)
}

private func nativeRDPErrorCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_error_event>?
) {
    guard let opaqueContext, let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_error_event>.size) else {
        return
    }
    let event = eventPointer.pointee
    let context = Unmanaged<NativeRDPCallbackContext>
        .fromOpaque(opaqueContext)
        .takeUnretainedValue()
    context.receiveError(generation: event.generation, status: event.status)
}

private func nativeRDPCertificateCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ challengePointer: UnsafePointer<mr_rdp_certificate_challenge>?
) {
    guard let opaqueContext, let challengePointer else { return }
    let context = Unmanaged<NativeRDPCallbackContext>
        .fromOpaque(opaqueContext)
        .takeUnretainedValue()
    // Capture response identity before validating/copying the borrowed views.
    let generation = challengePointer.pointee.generation
    let challengeID = challengePointer.pointee.challenge_id
    guard let snapshot = NativeCertificateSnapshot(copying: challengePointer) else {
        context.rejectMalformedCertificate(
            generation: generation,
            challengeID: challengeID
        )
        return
    }
    context.receiveCertificate(snapshot)
}

private func nativeRDPFrameCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ framePointer: UnsafePointer<mr_rdp_desktop_frame>?
) {
    guard let opaqueContext, let framePointer,
          let snapshot = NativeDesktopFrameSnapshot(copying: framePointer) else {
        return
    }
    let context = Unmanaged<NativeRDPCallbackContext>
        .fromOpaque(opaqueContext)
        .takeUnretainedValue()
    context.receiveFrame(snapshot)
}

private func nativeRDPChannelCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_channel_event>?
) {
    guard let opaqueContext, let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(MemoryLayout<mr_rdp_channel_event>.size)
    else { return }
    let event = eventPointer.pointee
    guard event.generation != 0,
          event.sequence != 0,
          event.reserved == 0,
          let channel = Phase0RDPChannel(rawValue: Int(event.channel)),
          let transition = Phase0ChannelTransition(rawValue: Int(event.transition))
    else { return }
    let context = Unmanaged<NativeRDPCallbackContext>
        .fromOpaque(opaqueContext)
        .takeUnretainedValue()
    context.receiveChannel(Phase0ChannelTelemetry(
        generation: event.generation,
        sequence: event.sequence,
        channel: channel,
        transition: transition
    ))
}

private func nativeRDPClipboardProbeCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_clipboard_probe_event>?
) {
    guard let opaqueContext, let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(
              MemoryLayout<mr_rdp_clipboard_probe_event>.size
          )
    else { return }
    let event = eventPointer.pointee
    guard event.generation != 0,
          event.sequence != 0,
          event.probe_id != 0,
          event.payload_byte_count >= 4,
          event.payload_byte_count <= Int(MR_RDP_MAX_CLIPBOARD_PROBE_UTF16LE_BYTES),
          let stage = Phase0ClipboardProbeStage(rawValue: Int(event.stage))
    else { return }
    let payloadSHA256 = withUnsafeBytes(of: event.payload_sha256) { bytes in
        bytes.prefix(Int(MR_RDP_SHA256_BYTES))
            .map { String(format: "%02X", $0) }
            .joined()
    }
    guard payloadSHA256.count == Int(MR_RDP_SHA256_BYTES) * 2 else { return }
    let context = Unmanaged<NativeRDPCallbackContext>
        .fromOpaque(opaqueContext)
        .takeUnretainedValue()
    context.receiveClipboardProbe(Phase0ClipboardProbeTelemetry(
        generation: event.generation,
        sequence: event.sequence,
        probeID: event.probe_id,
        stage: stage,
        payloadByteCount: event.payload_byte_count,
        payloadSHA256: payloadSHA256,
        statusCode: event.status
    ))
}

private func nativeRDPDisplayResizeCallback(
    _ opaqueContext: UnsafeMutableRawPointer?,
    _ eventPointer: UnsafePointer<mr_rdp_display_resize_event>?
) {
    guard let opaqueContext, let eventPointer,
          eventPointer.pointee.struct_size >= UInt32(
              MemoryLayout<mr_rdp_display_resize_event>.size
          )
    else { return }
    let event = eventPointer.pointee
    guard event.generation != 0,
          event.sequence != 0,
          event.request_id != 0,
          event.width >= UInt32(MR_RDP_MIN_DESKTOP_DIMENSION),
          event.width <= UInt32(MR_RDP_MAX_DESKTOP_DIMENSION),
          event.width.isMultiple(of: 2),
          event.height >= UInt32(MR_RDP_MIN_DESKTOP_DIMENSION),
          event.height <= UInt32(MR_RDP_MAX_DESKTOP_DIMENSION)
    else { return }
    let context = Unmanaged<NativeRDPCallbackContext>
        .fromOpaque(opaqueContext)
        .takeUnretainedValue()
    context.receiveDisplayResize(Phase0DisplayResizeTelemetry(
        generation: event.generation,
        sequence: event.sequence,
        requestID: event.request_id,
        width: event.width,
        height: event.height,
        statusCode: event.status
    ))
}

final class NativeRDPSession: @unchecked Sendable, HarnessInputSink {
    let generation: UInt64

    private let worker = DispatchQueue(
        label: "dev.mremote.phase0.rdp-session",
        qos: .userInitiated
    )
    private let context: NativeRDPCallbackContext
    private let journal: EventJournal
    private let onFinished: @MainActor @Sendable (UInt64, mr_rdp_status, mr_rdp_status?) -> Void
    private var didStart = false
    private var lastPointerX: UInt32 = 0
    private var lastPointerY: UInt32 = 0
    private var nextClipboardProbeID: UInt64 = 0
    private var nextDisplayResizeID: UInt64 = 0

    @MainActor
    init(
        generation: UInt64,
        journal: EventJournal,
        onStatus: @escaping @MainActor @Sendable (HarnessSessionStatus) -> Void,
        onFrame: @escaping @MainActor @Sendable (NativeDesktopFrameSnapshot) -> Void,
        onCertificate: @escaping @MainActor @Sendable (String) -> Void,
        onChannel: @escaping @MainActor @Sendable (Phase0ChannelTelemetry) -> Void,
        onClipboardProbe: @escaping @MainActor @Sendable (
            Phase0ClipboardProbeTelemetry
        ) -> Void,
        onDisplayResize: @escaping @MainActor @Sendable (
            Phase0DisplayResizeTelemetry
        ) -> Void,
        onUntrustedCertificate: @escaping @MainActor @Sendable (
            NativeCertificateReview,
            @escaping @Sendable (Bool) -> Void
        ) -> Void,
        onFinished: @escaping @MainActor @Sendable (
            UInt64,
            mr_rdp_status,
            mr_rdp_status?
        ) -> Void
    ) {
        self.generation = generation
        self.journal = journal
        self.onFinished = onFinished
        context = NativeRDPCallbackContext(
            onStatus: onStatus,
            onFrame: onFrame,
            onCertificate: onCertificate,
            onChannel: onChannel,
            onClipboardProbe: onClipboardProbe,
            onDisplayResize: onDisplayResize,
            onUntrustedCertificate: onUntrustedCertificate
        )
    }

    deinit {
        // The worker retains its callback context independently. If UI/session
        // ownership is lost without SceneDelegate's explicit shutdown path,
        // this thread-safe wake prevents a stranded blocking run/challenge.
        _ = context.requestStop()
    }

    @MainActor
    func start(
        _ connection: ValidatedRDPConnection,
        desktopWidth: UInt32,
        desktopHeight: UInt32
    ) {
        precondition(!didStart)
        didStart = true
        let generation = generation
        let context = context
        let onFinished = onFinished
        worker.async {
            let create = Self.createSession(
                connection: connection,
                generation: generation,
                desktopWidth: desktopWidth,
                desktopHeight: desktopHeight,
                context: context
            )
            // mr_rdp_session_create has now deep-copied or rejected the span.
            // Erase the app-model password before any network session runs.
            connection.password.clear()

            guard create.status == mr_rdp_status(MR_RDP_STATUS_OK),
                  let session = create.session else {
                Task { @MainActor in
                    onFinished(generation, create.status, nil)
                }
                return
            }

            context.install(session)
            let runStatus = mr_rdp_session_run(session)
            let destroyStatus = context.destroy()
            Task { @MainActor in
                onFinished(generation, runStatus, destroyStatus)
            }
        }
    }

    @MainActor
    func requestStop() {
        let status = context.requestStop()
        journal.append(.state, "native stop g=\(generation) status=\(status ?? 0)")
    }

    @MainActor
    func startClipboardProbe() {
        nextClipboardProbeID &+= 1
        if nextClipboardProbeID == 0 { nextClipboardProbeID = 1 }
        let probeID = nextClipboardProbeID
        let text = "mRemote Phase 0 CF_UNICODETEXT probe g=\(generation) id=\(probeID)"
        var payload: [UInt8] = []
        payload.reserveCapacity(text.utf16.count * 2 + 2)
        for codeUnit in text.utf16 {
            payload.append(UInt8(truncatingIfNeeded: codeUnit))
            payload.append(UInt8(truncatingIfNeeded: codeUnit >> 8))
        }
        payload.append(0)
        payload.append(0)
        defer {
            payload.withUnsafeMutableBytes { buffer in
                guard let address = buffer.baseAddress, !buffer.isEmpty else { return }
                _ = memset_s(address, buffer.count, 0, buffer.count)
            }
        }

        var probe = mr_rdp_clipboard_probe()
        mr_rdp_clipboard_probe_init(&probe)
        probe.probe_id = probeID
        probe.utf16le_byte_count = payload.count
        let status = payload.withUnsafeBytes { bytes -> mr_rdp_status? in
            guard let address = bytes.bindMemory(to: UInt8.self).baseAddress else {
                return mr_rdp_status(MR_RDP_ERROR_INVALID_DATA)
            }
            probe.utf16le_bytes = address
            return context.startClipboardProbe(&probe)
        }
        journal.append(
            status == mr_rdp_status(MR_RDP_STATUS_OK) ? .send : .drop,
            "cliprdr probe queued g=\(generation) id=\(probeID) bytes=\(payload.count) status=\(status ?? mr_rdp_status(MR_RDP_ERROR_INVALID_STATE))"
        )
    }

    @MainActor
    func requestDisplayResize(width: UInt32, height: UInt32) {
        nextDisplayResizeID &+= 1
        if nextDisplayResizeID == 0 { nextDisplayResizeID = 1 }
        var request = mr_rdp_display_resize_request()
        mr_rdp_display_resize_request_init(&request)
        request.request_id = nextDisplayResizeID
        request.width = width
        request.height = height
        let status = context.requestDisplayResize(&request)
        journal.append(
            status == mr_rdp_status(MR_RDP_STATUS_OK) ? .send : .drop,
            "disp resize queued g=\(generation) id=\(request.request_id) size=\(width)x\(height) status=\(status ?? mr_rdp_status(MR_RDP_ERROR_INVALID_STATE))"
        )
    }

    @MainActor
    func enqueue(_ input: OutboundInput, generation inputGeneration: UInt64) {
        switch input {
        case let .hardwareKey(usage, transition):
            sendKey(usage: usage, transition: transition, inputGeneration: inputGeneration)
        case let .pointer(payload):
            sendPointer(payload, inputGeneration: inputGeneration)
        case let .hostASCII(text):
            journal.append(
                .drop,
                "native host ASCII transport not implemented g=\(inputGeneration) UTF16=\(text.utf16.count)"
            )
        case let .committedText(text):
            journal.append(
                .drop,
                "native Unicode transport not implemented g=\(inputGeneration) UTF16=\(text.utf16.count)"
            )
        }
    }

    @MainActor
    private func sendKey(
        usage: UInt16,
        transition: KeyTransition,
        inputGeneration: UInt64
    ) {
        let scanCode: RDPSet1ScanCode
        do {
            scanCode = try RDPScanCodeMapper.set1ScanCode(forHIDUsage: usage)
        } catch {
            journal.appendKeyboardEvent(
                .drop,
                usage: usage,
                "native key mapping g=\(inputGeneration) error=\(error)"
            )
            return
        }

        var event = mr_rdp_key_event()
        mr_rdp_key_event_init(&event)
        event.code = UInt16(scanCode.value)
        event.extended = scanCode.isExtended ? 1 : 0
        event.extended1 = 0
        event.action = mr_rdp_key_action(
            transition == .down ? MR_RDP_KEY_DOWN : MR_RDP_KEY_UP
        )
        let status = context.sendKey(&event)
        let kind: EventJournal.Kind = status == mr_rdp_status(MR_RDP_STATUS_OK) ? .send : .drop
        let statusDescription = status ?? mr_rdp_status(MR_RDP_ERROR_INVALID_STATE)
        journal.appendKeyboardEvent(
            kind,
            usage: usage,
            status == mr_rdp_status(MR_RDP_STATUS_OK)
                ? "native input-g=\(inputGeneration) key \(scanCode) \(transition == .down ? "down" : "up")"
                : "native input-g=\(inputGeneration) status=\(statusDescription) key \(scanCode) \(transition == .down ? "down" : "up")"
        )
    }

    @MainActor
    private func sendPointer(_ payload: PointerPayload, inputGeneration: UInt64) {
        var event = mr_rdp_pointer_event()
        mr_rdp_pointer_event_init(&event)

        switch payload {
        case let .move(remote):
            lastPointerX = nativeCoordinate(remote.x)
            lastPointerY = nativeCoordinate(remote.y)
            event.kind = mr_rdp_pointer_kind(MR_RDP_POINTER_MOVE)
        case let .button(button, transition, remote):
            if let remote {
                lastPointerX = nativeCoordinate(remote.x)
                lastPointerY = nativeCoordinate(remote.y)
            }
            event.kind = mr_rdp_pointer_kind(MR_RDP_POINTER_BUTTON)
            switch button {
            case .left:
                event.button = mr_rdp_pointer_button(MR_RDP_POINTER_BUTTON_LEFT)
            case .right:
                event.button = mr_rdp_pointer_button(MR_RDP_POINTER_BUTTON_RIGHT)
            case .middle:
                event.button = mr_rdp_pointer_button(MR_RDP_POINTER_BUTTON_MIDDLE)
            }
            event.action = mr_rdp_key_action(
                transition == .down ? MR_RDP_KEY_DOWN : MR_RDP_KEY_UP
            )
        case let .scroll(horizontal, vertical):
            let wheelX = nativeWheel(horizontal)
            let wheelY = nativeWheel(vertical)
            guard wheelX != 0 || wheelY != 0 else { return }
            event.kind = mr_rdp_pointer_kind(MR_RDP_POINTER_WHEEL)
            event.wheel_x = wheelX
            event.wheel_y = wheelY
        }
        event.x = lastPointerX
        event.y = lastPointerY

        let status = context.sendPointer(&event)
        recordSend(
            status: status,
            inputGeneration: inputGeneration,
            description: payload.diagnosticDescription
        )
    }

    @MainActor
    private func recordSend(
        status: mr_rdp_status?,
        inputGeneration: UInt64,
        description: String
    ) {
        if status == mr_rdp_status(MR_RDP_STATUS_OK) {
            journal.append(.send, "native input-g=\(inputGeneration) \(description)")
        } else {
            journal.append(
                .drop,
                "native input-g=\(inputGeneration) status=\(status ?? mr_rdp_status(MR_RDP_ERROR_INVALID_STATE)) \(description)"
            )
        }
    }

    nonisolated private static func createSession(
        connection: ValidatedRDPConnection,
        generation: UInt64,
        desktopWidth: UInt32,
        desktopHeight: UInt32,
        context: NativeRDPCallbackContext
    ) -> (status: mr_rdp_status, session: OpaquePointer?) {
        var callbacks = mr_rdp_callbacks()
        mr_rdp_callbacks_init(&callbacks)
        callbacks.on_state_changed = nativeRDPStateCallback
        callbacks.on_certificate_challenge = nativeRDPCertificateCallback
        callbacks.on_error = nativeRDPErrorCallback
        callbacks.on_desktop_frame = nativeRDPFrameCallback
        callbacks.on_channel_event = nativeRDPChannelCallback
        callbacks.on_clipboard_probe_event = nativeRDPClipboardProbeCallback
        callbacks.on_display_resize_event = nativeRDPDisplayResizeCallback

        var config = mr_rdp_config()
        mr_rdp_config_init(&config)
        config.generation = generation
        config.port = connection.descriptor.port
        config.desktop_width = desktopWidth
        config.desktop_height = desktopHeight
        config.username_length = connection.descriptor.username.utf8.count
        config.domain_length = connection.descriptor.domain.utf8.count

        let opaqueContext = Unmanaged.passUnretained(context).toOpaque()
        var session: OpaquePointer?
        let status = connection.descriptor.hostname.withCString { hostname in
            connection.descriptor.username.withCString { username in
                connection.password.withUTF8Span { password, passwordLength in
                    config.hostname = hostname
                    config.username = username
                    config.password = password
                    config.password_length = passwordLength
                    if connection.descriptor.domain.isEmpty {
                        config.domain = nil
                        return mr_rdp_session_create(
                            &config,
                            &callbacks,
                            opaqueContext,
                            &session
                        )
                    }
                    return connection.descriptor.domain.withCString { domain in
                        config.domain = domain
                        return mr_rdp_session_create(
                            &config,
                            &callbacks,
                            opaqueContext,
                            &session
                        )
                    }
                }
            }
        }
        return (status, session)
    }

    @MainActor
    private func nativeCoordinate(_ value: CGFloat) -> UInt32 {
        guard value.isFinite, value > 0 else { return 0 }
        return UInt32(min(value.rounded(), CGFloat(UInt32.max)))
    }

    @MainActor
    private func nativeWheel(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        // PointerEventArbiter retains fractional device input. Keep this
        // boundary defensive without rounding a stray fraction away from zero.
        let wholeUnits = value.rounded(.towardZero)
        return Int32(min(max(wholeUnits, Double(Int32.min)), Double(Int32.max)))
    }
}
#endif
