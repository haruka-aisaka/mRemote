import Foundation
import Observation
import SessionCore

/// The editable form behind the add/edit sheet.
///
/// It is a model rather than `@State` in the view so the validation rules have
/// one home and can be tested without presenting anything.
@MainActor
@Observable
final class ProfileEditorModel: Identifiable {
    enum Mode {
        case create
        case edit(ConnectionProfile)
    }

    nonisolated let id = UUID()

    var displayName: String
    var host: String
    var portText: String
    var username: String
    var domain: String
    var password: String
    var keyboardLayout: Inheritable<KeyboardLayoutPreference>
    var securityPolicy: SecurityPolicy
    var audioPlayback: Inheritable<Bool>
    var clipboardPolicy: Inheritable<ClipboardPolicy>
    var scrollDirection: Inheritable<ScrollDirection>

    private let existing: ConnectionProfile?

    init(mode: Mode, password: String? = nil) {
        switch mode {
        case .create:
            existing = nil
            displayName = ""
            host = ""
            portText = "3389"
            username = ""
            domain = ""
            keyboardLayout = .inherit
            securityPolicy = .secureAutomatic
            audioPlayback = .inherit
            clipboardPolicy = .inherit
            scrollDirection = .inherit
        case .edit(let profile):
            existing = profile
            displayName = profile.displayName
            host = profile.endpoint.host
            portText = String(profile.endpoint.port)
            username = profile.account.username ?? ""
            domain = profile.account.domain ?? ""
            let rdp = profile.configuration.rdp ?? RDPConfiguration()
            keyboardLayout = rdp.keyboardLayout
            securityPolicy = rdp.securityPolicy
            audioPlayback = rdp.audioPlayback
            clipboardPolicy = rdp.clipboardPolicy
            scrollDirection = rdp.scrollDirection
        }
        self.password = password ?? ""
    }

    var isEditing: Bool { existing != nil }

    var title: String { isEditing ? "接続先を編集" : "接続先を追加" }

    var port: UInt16? {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }
        return value
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    var isValid: Bool { !trimmedHost.isEmpty && port != nil }

    /// The Eisu/Kana promise only holds for the Japanese layout, so the form
    /// says where it does not rather than silently mapping the keys anyway.
    var showsJapaneseKeyWarning: Bool {
        if case .explicit(let layout) = keyboardLayout, layout != .japanese { return true }
        return false
    }

    var showsLegacySecurityWarning: Bool { securityPolicy == .legacyExplicit }

    /// A name is optional in the form; falling back to the host is friendlier
    /// than refusing to save.
    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? trimmedHost : trimmed
    }

    func makeProfile(now: Date = Date()) -> ConnectionProfile? {
        guard let port else { return nil }
        let configuration = RDPConfiguration(
            keyboardLayout: keyboardLayout,
            audioPlayback: audioPlayback,
            clipboardPolicy: clipboardPolicy,
            scrollDirection: scrollDirection,
            securityPolicy: securityPolicy
        )
        var profile = existing ?? ConnectionProfile(
            displayName: resolvedDisplayName,
            endpoint: RemoteEndpoint(host: trimmedHost, port: port),
            createdAt: now,
            updatedAt: now
        )
        profile.displayName = resolvedDisplayName
        profile.endpoint = RemoteEndpoint(host: trimmedHost, port: port)
        profile.account.username = username.isEmpty ? nil : username
        profile.account.domain = domain.isEmpty ? nil : domain
        profile.configuration = .rdp(configuration)
        profile.updatedAt = now
        return profile
    }
}
