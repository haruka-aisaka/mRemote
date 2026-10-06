import Foundation
import SessionCore

/// Where a physical key transition was observed.
public enum KeyboardSource: String, Hashable, Sendable, CaseIterable {
    /// `pressesBegan`/`pressesEnded` on the first responder.
    case uiKit
    /// `GCKeyboard.coalesced`'s `keyChangedHandler`.
    case gameController
}

/// Which source a usage's remote transitions are taken from.
public enum KeyboardSourceChoice: Hashable, Sendable {
    case uiKit
    case gameController
    /// Neither source delivers a reliable down/up pair; the key is never sent
    /// and the on-screen key bar is the way to type it.
    case unsupported

    func accepts(_ source: KeyboardSource) -> Bool {
        switch (self, source) {
        case (.uiKit, .uiKit), (.gameController, .gameController): return true
        default: return false
        }
    }
}

/// A static, per-usage choice of source.
///
/// docs/input-design.md section 5: UIKit and GameController share no event
/// identity and no comparable timestamp, so a press is never merged across
/// them by timing. Each usage is bound to exactly one source up front, and the
/// other source only ever updates the physical state.
public struct KeyboardSourcePolicy: Hashable, Sendable {
    public let overrides: [UInt16: KeyboardSourceChoice]

    public init(overrides: [UInt16: KeyboardSourceChoice] = [:]) {
        self.overrides = overrides
    }

    public func choice(for usage: UInt16) -> KeyboardSourceChoice {
        overrides[usage] ?? .uiKit
    }

    /// What Phase 0 established on the baseline keyboard (Apple Magic
    /// Keyboard JIS): UIKit delivered a down and an up for every usage,
    /// including LANG1/LANG2, so nothing needs GameController. A key that
    /// turns out otherwise on other hardware is added here, not detected at
    /// run time.
    public static let baseline = KeyboardSourcePolicy()
}

/// Why everything held was released. Counted, never logged with key content.
public enum InputReleaseReason: String, Hashable, Sendable, CaseIterable {
    case gateClosed
    case focusLost
    case pressesCancelled
    case keyboardDisconnected
    case sourcePolicyChanged
    case surfaceRemoved
}

/// Turns transitions from two keyboard sources into one stream for the
/// remote host.
///
/// The interesting state is the split between what is *physically* held -
/// observed by either source, whether or not input could be delivered - and
/// what the host was *told* is held, which `KeyboardInputRouter` owns. A
/// `releaseAll` clears the latter at once, and moves whatever is still
/// physically down into quarantine: its eventual up must not reach the host
/// (the host already got one), and neither may a repeat or a second down
/// from a press that began before the release.
public struct KeyboardEventArbiter: Sendable {
    public private(set) var policy: KeyboardSourcePolicy
    public private(set) var router: KeyboardInputRouter
    public private(set) var isGateOpen = false
    public private(set) var quarantined: Set<UInt16> = []
    public private(set) var diagnostics = InputDiagnostics()

    private var physical: [KeyboardSource: Set<UInt16>] = [:]

    public init(
        policy: KeyboardSourcePolicy = .baseline,
        repeatSettings: KeyRepeatSettings = .normal
    ) {
        self.policy = policy
        self.router = KeyboardInputRouter(repeatSettings: repeatSettings)
    }

    public var repeatTarget: UInt16? { router.repeatTarget }
    public var repeatSettings: KeyRepeatSettings { router.repeatSettings }
    public var pressedUsages: Set<UInt16> { router.pressedUsages }

    /// Usages either source currently reports as physically held.
    public var physicallyHeld: Set<UInt16> {
        physical.values.reduce(into: Set<UInt16>()) { $0.formUnion($1) }
    }

    public mutating func setTraceEnabled(_ enabled: Bool) {
        diagnostics.setTraceEnabled(enabled)
    }

    public mutating func receive(
        usage: UInt16,
        transition: InputTransition,
        from source: KeyboardSource
    ) -> KeyboardRouterOutput {
        let isDuplicatePhysicalDown = notePhysical(usage, transition, source)

        guard policy.choice(for: usage).accepts(source) else {
            // The other source's observation still counts for physical state,
            // which is how a quarantine can clear while the surface is not the
            // first responder.
            diagnostics.record(.otherSource, usage: usage, transition: transition, source: source)
            if transition == .up { liftQuarantineIfReleased(usage) }
            return .none
        }

        if quarantined.contains(usage) {
            diagnostics.record(.quarantined, usage: usage, transition: transition, source: source)
            if transition == .up { liftQuarantineIfReleased(usage) }
            return .none
        }

        guard isGateOpen else {
            diagnostics.record(.gated, usage: usage, transition: transition, source: source)
            return .none
        }

        let output = router.receive(usage: usage, transition: transition)
        if output.events.isEmpty {
            diagnostics.record(
                isDuplicatePhysicalDown || transition == .down ? .duplicate : .orphan,
                usage: usage,
                transition: transition,
                source: source
            )
        } else {
            diagnostics.record(.forwarded, usage: usage, transition: transition, source: source)
        }
        return output
    }

    /// Opening the gate delivers nothing by itself; closing it releases
    /// everything the host believes is held.
    public mutating func setGate(open: Bool) -> KeyboardRouterOutput {
        guard open != isGateOpen else { return .none }
        isGateOpen = open
        return open ? .none : releaseAll(reason: .gateClosed)
    }

    public mutating func releaseAll(reason: InputReleaseReason) -> KeyboardRouterOutput {
        diagnostics.noteRelease(reason)
        quarantined.formUnion(physicallyHeld)
        return router.releaseAll()
    }

    /// A source went away: it will report no more ups, so whatever it held is
    /// no longer physically held as far as anything here can know.
    public mutating func sourceDisconnected(_ source: KeyboardSource) -> KeyboardRouterOutput {
        let output = releaseAll(reason: .keyboardDisconnected)
        physical[source] = nil
        quarantined.formIntersection(physicallyHeld)
        return output
    }

    /// Replaces the physical picture with an authoritative snapshot -
    /// `GCKeyboard`'s per-key `isPressed` - so a quarantine left behind by
    /// presses whose ups went to another app can be lifted without making the
    /// user press those keys once more for nothing.
    public mutating func reconcile(physicallyHeld held: Set<UInt16>) {
        for source in KeyboardSource.allCases {
            physical[source] = physical[source].map { $0.intersection(held) }
        }
        quarantined.formIntersection(held)
    }

    public mutating func repeatDown() -> KeyboardInput? {
        guard isGateOpen else { return nil }
        return router.repeatDown()
    }

    public mutating func setRepeatSettings(_ settings: KeyRepeatSettings) -> KeyboardRouterOutput {
        router.setRepeatSettings(settings)
    }

    /// Changes take effect only at a neutral point: with keys held, a press
    /// that began under one source could end under the other.
    public mutating func setPolicy(_ newPolicy: KeyboardSourcePolicy) -> KeyboardRouterOutput {
        guard newPolicy != policy else { return .none }
        let output = releaseAll(reason: .sourcePolicyChanged)
        policy = newPolicy
        return output
    }

    @discardableResult
    private mutating func notePhysical(
        _ usage: UInt16,
        _ transition: InputTransition,
        _ source: KeyboardSource
    ) -> Bool {
        switch transition {
        case .down:
            return !physical[source, default: []].insert(usage).inserted
        case .up:
            physical[source]?.remove(usage)
            return false
        }
    }

    private mutating func liftQuarantineIfReleased(_ usage: UInt16) {
        guard !physicallyHeld.contains(usage) else { return }
        quarantined.remove(usage)
    }
}
