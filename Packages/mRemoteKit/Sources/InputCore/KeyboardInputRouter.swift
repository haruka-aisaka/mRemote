import Foundation
import SessionCore

/// What one keyboard observation produced.
public struct KeyboardRouterOutput: Hashable, Sendable {
    public let events: [KeyboardInput]
    /// True when the caller must cancel any pending repeat and, if
    /// `repeatTarget` is non-nil, arm a fresh `initialDelay`. False leaves an
    /// already-running repeat alone - which is what stops a modifier pressed
    /// during a held key from restarting that key's typematic.
    public let restartsRepeat: Bool
    public let repeatTarget: UInt16?

    static let none = KeyboardRouterOutput(events: [], restartsRepeat: false, repeatTarget: nil)
}

/// Normalises physical key transitions into what the remote host is told.
///
/// The state here is what separates a keyboard that works from one that
/// leaves a modifier stuck down on the server - which is worse than it sounds,
/// because a stuck Control turns every subsequent keystroke into a shortcut.
///
/// This is UIKit-only by design for now: `GCKeyboard`, the per-usage source
/// policy and the arbitration between the two are Phase 3, and the Phase 0
/// harness remains the fixture where that behaviour is exercised.
public struct KeyboardInputRouter: Sendable {
    public var repeatSettings: KeyRepeatSettings

    /// Usages this side has told the host are down. Deliberately separate from
    /// what is physically held: an event dropped while input was gated must
    /// not later produce an up the host never had a down for.
    public private(set) var pressedUsages: Set<UInt16> = []
    /// Repeat-eligible held keys, oldest first. A physical keyboard repeats
    /// the newest key and falls back to one still held when it is released,
    /// so the order matters and a set would lose it.
    private var repeatCandidates: [UInt16] = []
    public private(set) var repeatTarget: UInt16?

    public init(repeatSettings: KeyRepeatSettings = .normal) {
        self.repeatSettings = repeatSettings
    }

    public mutating func receive(
        usage: UInt16,
        transition: InputTransition
    ) -> KeyboardRouterOutput {
        switch transition {
        case .down:
            // A duplicate down is dropped rather than forwarded. The host is
            // told about repeats explicitly through `repeatDown`, and a second
            // physical down without an up in between means an event was lost,
            // not that the key was pressed twice.
            guard pressedUsages.insert(usage).inserted else { return .none }
            return KeyboardRouterOutput(
                events: [KeyboardInput(usage: usage, transition: .down)],
                restartsRepeat: noteDown(usage),
                repeatTarget: repeatTarget
            )

        case .up:
            // An orphan up is dropped for the same reason: sending an up for a
            // key the host never saw pressed can clear a modifier the user is
            // still holding.
            guard pressedUsages.remove(usage) != nil else { return .none }
            return KeyboardRouterOutput(
                events: [KeyboardInput(usage: usage, transition: .up)],
                restartsRepeat: noteUp(usage),
                repeatTarget: repeatTarget
            )
        }
    }

    /// Releases everything this side believes is held.
    ///
    /// docs/architecture.md section 10 requires it on focus loss, session
    /// switch and scene deactivation. Ordered by usage so a trace is
    /// reproducible; the host does not care, but a flaky test would.
    public mutating func releaseAll() -> KeyboardRouterOutput {
        let held = pressedUsages.sorted()
        pressedUsages.removeAll(keepingCapacity: true)
        repeatCandidates.removeAll(keepingCapacity: true)
        repeatTarget = nil
        return KeyboardRouterOutput(
            events: held.map { KeyboardInput(usage: $0, transition: .up) },
            restartsRepeat: true,
            repeatTarget: nil
        )
    }

    /// The repeat timer fired. Nil means the target is gone and the caller
    /// should stop repeating.
    ///
    /// Re-checked here rather than trusted from arming time: a release, a
    /// `releaseAll` or a settings change can all happen underneath a pending
    /// fire, and a repeat must never outlive the down it extends.
    public mutating func repeatDown() -> KeyboardInput? {
        guard repeatSettings.isEnabled,
              let usage = repeatTarget,
              pressedUsages.contains(usage) else {
            repeatTarget = nil
            return nil
        }
        return KeyboardInput(usage: usage, transition: .down, isRepeat: true)
    }

    /// Turning repeat off must stop a key that is already repeating without
    /// releasing it: the user is still holding it.
    public mutating func setRepeatSettings(_ settings: KeyRepeatSettings) -> KeyboardRouterOutput {
        guard settings != repeatSettings else { return .none }
        repeatSettings = settings
        return KeyboardRouterOutput(
            events: [],
            restartsRepeat: true,
            repeatTarget: refreshRepeatTarget()
        )
    }

    private mutating func noteDown(_ usage: UInt16) -> Bool {
        guard KeyRepeatEligibility.repeats(usage) else {
            // A modifier held during a repeating key must not steal the
            // repeat, and must not restart it either.
            return false
        }
        repeatCandidates.removeAll { $0 == usage }
        repeatCandidates.append(usage)
        _ = refreshRepeatTarget()
        return true
    }

    private mutating func noteUp(_ usage: UInt16) -> Bool {
        guard repeatCandidates.contains(usage) else { return false }
        let wasTarget = repeatTarget == usage
        repeatCandidates.removeAll { $0 == usage }
        guard wasTarget else { return false }
        _ = refreshRepeatTarget()
        return true
    }

    @discardableResult
    private mutating func refreshRepeatTarget() -> UInt16? {
        repeatTarget = repeatSettings.isEnabled ? repeatCandidates.last : nil
        return repeatTarget
    }
}
