import Foundation

@MainActor
final class EventJournal {
    enum Kind: String {
        case observation = "OBS"
        case send = "SEND"
        case drop = "DROP"
        case state = "STATE"
        case warning = "WARN"
    }

    struct Counters {
        var observed = 0
        var sent = 0
        var dropped = 0
    }

    var onChange: (() -> Void)?

    private(set) var counters = Counters()
    private(set) var lines: [String] = []
    private let maximumLines = 2_000
    private var sequence: UInt64 = 0

    func append(_ kind: Kind, _ message: String) {
        record(kind, message: message)
    }

    /// Counts every keyboard outcome but creates an event-level journal line
    /// only for the explicit non-printing Release diagnostic allow-list.
    /// Callers must use this entry point for every usage-bearing key event.
    func appendKeyboardEvent(_ kind: Kind, usage: UInt16, _ message: @autoclosure () -> String) {
        guard HIDUsage.isReleaseDiagnosticAllowListed(usage) else {
            record(kind, message: nil)
            return
        }
        record(kind, message: message())
    }

    private func record(_ kind: Kind, message: String?) {
        sequence &+= 1
        switch kind {
        case .observation: counters.observed += 1
        case .send: counters.sent += 1
        case .drop: counters.dropped += 1
        case .state, .warning: break
        }
        if let message {
            let uptime = ProcessInfo.processInfo.systemUptime
            lines.append(String(format: "%06llu %10.3f %@ %@", sequence, uptime, kind.rawValue, message))
            if lines.count > maximumLines {
                lines.removeFirst(lines.count - maximumLines)
            }
        }
        onChange?()
    }

    func clear() {
        lines.removeAll(keepingCapacity: true)
        counters = Counters()
        sequence = 0
        onChange?()
    }

    var displayText: String {
        lines.suffix(250).joined(separator: "\n")
    }

    func exportText(environmentNotes: String) -> String {
        let header = """
        Phase0Harness input record
        exported: \(ISO8601DateFormatter().string(from: Date()))
        environment notes:
        \(environmentNotes.isEmpty ? "(not entered)" : environmentNotes)

        """
        return header + lines.joined(separator: "\n")
    }
}
@MainActor
final class RecordingInputSink: HarnessInputSink {
    private let journal: EventJournal
    private let maximumEvents: Int
    private(set) var events: [(OutboundInput, UInt64)] = []

    init(journal: EventJournal, maximumEvents: Int = 2_000) {
        precondition(maximumEvents > 0)
        self.journal = journal
        self.maximumEvents = maximumEvents
    }

    func enqueue(_ input: OutboundInput, generation: UInt64) {
#if DEBUG
        events.append((input, generation))
        if events.count > maximumEvents {
            events.removeFirst(events.count - maximumEvents)
        }
#endif
        if case let .hardwareKey(usage, _) = input {
            journal.appendKeyboardEvent(
                .send,
                usage: usage,
                "g=\(generation) \(input.diagnosticDescription)"
            )
        } else {
            journal.append(.send, "g=\(generation) \(input.diagnosticDescription)")
        }
    }

    func clear() {
        events.removeAll(keepingCapacity: true)
    }
}
