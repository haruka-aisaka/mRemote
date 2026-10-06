import Foundation
import Observation
import InputCore

/// The app-wide view of the focused surface's input counters, for the
/// diagnostics screen.
///
/// docs/input-design.md section 11: the counters are always available; the
/// allow-listed trace is an explicit, time-limited opt-in held in memory only.
/// Leaving the trace on by accident would be the failure, so it switches
/// itself off.
@MainActor
@Observable
final class InputDiagnosticsCenter {
    static let traceDuration: Duration = .seconds(10 * 60)

    private(set) var latest = InputDiagnostics()
    private(set) var isTraceRequested = false
    private(set) var traceEndsAt: Date?
    private var expiry: Task<Void, Never>?

    func update(_ diagnostics: InputDiagnostics) {
        latest = diagnostics
    }

    func setTraceRequested(_ requested: Bool) {
        expiry?.cancel()
        expiry = nil
        isTraceRequested = requested
        traceEndsAt = nil
        guard requested else { return }
        traceEndsAt = Date().addingTimeInterval(10 * 60)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: Self.traceDuration)
            guard !Task.isCancelled else { return }
            self?.setTraceRequested(false)
        }
    }
}
