import Foundation
import SessionCore

/// What happened to one observed key transition.
public enum InputOutcome: String, Hashable, Sendable, CaseIterable {
    case forwarded
    /// A down for a key the host already holds.
    case duplicate
    /// An up for a key the host was never told about.
    case orphan
    /// Observed on the source this usage is not bound to.
    case otherSource
    /// Swallowed because the press began before a `releaseAll`.
    case quarantined
    /// The input gate was closed: menu, another session, inactive scene.
    case gated
}

/// One allow-listed transition in the opt-in trace.
public struct InputTraceEntry: Hashable, Sendable {
    public let sequence: Int
    public let usage: UInt16
    public let transition: InputTransition
    public let source: KeyboardSource
    public let outcome: InputOutcome
}

/// Counters, and an opt-in trace of non-character keys only.
///
/// docs/input-design.md section 11: a usage/scan-code time series can
/// reconstruct what was typed even without characters, so the trace is
/// restricted to an allow-list - the Japanese input-mode keys, the
/// international keys and the modifiers - is memory-only, and is off unless
/// the user turns it on. The counters carry no key identity at all.
public struct InputDiagnostics: Hashable, Sendable {
    public static let traceCapacity = 200

    public private(set) var outcomes: [InputOutcome: Int] = [:]
    public private(set) var releases: [InputReleaseReason: Int] = [:]
    public private(set) var isTraceEnabled = false
    public private(set) var trace: [InputTraceEntry] = []
    private var nextSequence = 0

    public init() {}

    /// Usages that never carry text: LANG1-9, International1-5, Caps Lock
    /// and the eight modifiers.
    public static func isTraceable(_ usage: UInt16) -> Bool {
        switch usage {
        case 0x39, 0x87...0x8B, 0x90...0x98, 0xE0...0xE7: return true
        default: return false
        }
    }

    public func count(_ outcome: InputOutcome) -> Int { outcomes[outcome, default: 0] }

    public func count(_ reason: InputReleaseReason) -> Int { releases[reason, default: 0] }

    mutating func setTraceEnabled(_ enabled: Bool) {
        isTraceEnabled = enabled
        if !enabled { trace.removeAll() }
    }

    mutating func record(
        _ outcome: InputOutcome,
        usage: UInt16,
        transition: InputTransition,
        source: KeyboardSource
    ) {
        outcomes[outcome, default: 0] += 1
        guard isTraceEnabled, Self.isTraceable(usage) else { return }
        nextSequence += 1
        trace.append(InputTraceEntry(
            sequence: nextSequence,
            usage: usage,
            transition: transition,
            source: source,
            outcome: outcome
        ))
        if trace.count > Self.traceCapacity {
            trace.removeFirst(trace.count - Self.traceCapacity)
        }
    }

    mutating func noteRelease(_ reason: InputReleaseReason) {
        releases[reason, default: 0] += 1
    }
}
