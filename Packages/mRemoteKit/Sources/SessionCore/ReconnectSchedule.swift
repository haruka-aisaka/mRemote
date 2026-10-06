import Foundation

/// When to try again after a connection dropped, if at all.
///
/// docs/architecture.md section 10: reconnection follows the configured
/// policy, is never attempted for a failure that needs the user (a refused
/// password retried automatically is how an account gets locked), and only
/// applies to a session that had actually connected - a first attempt that
/// fails is reported, not retried behind the user's back.
public struct ReconnectSchedule: Hashable, Sendable {
    public let delays: [Duration]

    public init(delays: [Duration] = [.seconds(1), .seconds(2), .seconds(4)]) {
        self.delays = delays
    }

    public var maximumAttempts: Int { delays.count }

    /// The wait before attempt number `attempt` (1-based), or nil to stop.
    public func delay(
        beforeAttempt attempt: Int,
        after error: RemoteSessionError?,
        policy: ReconnectPolicy,
        hadConnected: Bool
    ) -> Duration? {
        guard policy == .automatic,
              hadConnected,
              let error, error.isRetriable,
              attempt >= 1, attempt <= delays.count else {
            return nil
        }
        return delays[attempt - 1]
    }
}
