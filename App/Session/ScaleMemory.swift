import Foundation
import SessionCore

/// The display scale each connection was last viewed at, so it opens that
/// way next time (docs/changes/2026-10-25-remember-scale.md).
///
/// Kept on the device rather than in the profile document: it is how this
/// screen shows that host, not part of the connection. Remembered the moment
/// it changes, so it survives however the session ends.
struct ScaleMemory {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func key(_ profile: ProfileID) -> String {
        "remembered-scale.\(profile.rawValue.uuidString)"
    }

    /// Fitted for a connection never viewed otherwise.
    func scale(for profile: ProfileID?) -> InitialScale {
        guard let profile,
              let raw = defaults.string(forKey: Self.key(profile)),
              let scale = InitialScale(rawValue: raw) else { return .fit }
        return scale
    }

    func remember(_ scale: InitialScale, for profile: ProfileID?) {
        guard let profile else { return }
        defaults.set(scale.rawValue, forKey: Self.key(profile))
    }

    func copy(from source: ProfileID, to destination: ProfileID) {
        guard let raw = defaults.string(forKey: Self.key(source)) else { return }
        defaults.set(raw, forKey: Self.key(destination))
    }

    func forget(_ profile: ProfileID) {
        defaults.removeObject(forKey: Self.key(profile))
    }
}
