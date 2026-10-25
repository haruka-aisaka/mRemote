import Foundation
import SessionCore

/// Where the previous version kept the scale each connection was last viewed
/// at (docs/changes/2026-10-25-remember-scale.md). It is now the connection's
/// own setting (docs/changes/2026-10-25-session-settings-writeback.md); this
/// is read once at launch to move what was kept there.
struct ScaleMemory {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static func key(_ profile: ProfileID) -> String {
        "remembered-scale.\(profile.rawValue.uuidString)"
    }

    func remembered(for profile: ProfileID) -> InitialScale? {
        defaults.string(forKey: Self.key(profile)).flatMap(InitialScale.init(rawValue:))
    }

    /// The previous version's way of keeping it; kept for the tests that
    /// stand in for a device upgraded from it.
    func remember(_ scale: InitialScale, for profile: ProfileID) {
        defaults.set(scale.rawValue, forKey: Self.key(profile))
    }

    func forget(_ profile: ProfileID) {
        defaults.removeObject(forKey: Self.key(profile))
    }
}
