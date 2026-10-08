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
        /// A new profile filled in from a `.rdp` file or an `rdp://` link,
        /// with the settings it named that this app does not carry out.
        case importing(ConnectionProfile, unsupported: [String])
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
    var resolutionPolicy: Inheritable<ResolutionPolicy>

    // RD Gateway.
    var usesGateway = false
    var gatewayHost = ""
    var gatewayPortText = String(RDPGatewayConfiguration.defaultPort)
    var gatewayUsesComputerCredentials = true
    var gatewayUsername = ""
    var gatewayDomain = ""
    var gatewayPassword = ""
    var gatewayBypassesLocal = false

    // The folder shared as a drive.
    enum SharedFolderChoice: Hashable {
        case none
        case appDocuments
        case picked(bookmark: Data, name: String)
    }
    var sharedFolder: SharedFolderChoice = .none

    var group = ""
    var isFavorite = false
    var redirectsMicrophone = false
    var usesH264 = true
    var remotePlatform = RemotePlatform.standard
    var streamQuality = StreamQuality.automatic
    var remoteProgram = ""
    var remoteArguments = ""
    var wakesOnLAN = false
    var macAddress = ""
    var wakeTarget = WakeOnLANConfiguration.defaultTarget
    var wakePortText = String(WakeOnLANConfiguration.defaultPort)
    var wakesBeforeConnecting = true
    var driveName = "mRemote"

    private let existing: ConnectionProfile?
    /// What a new profile is built on: an import's settings beyond the form.
    private let base: RDPConfiguration?
    /// Shown above the form for an import.
    let unsupportedImportSettings: [String]
    let isImport: Bool

    init(mode: Mode, password: String? = nil) {
        switch mode {
        case .create:
            existing = nil
            base = nil
            unsupportedImportSettings = []
            isImport = false
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
            resolutionPolicy = .inherit
        case .edit(let profile), .importing(let profile, _):
            if case .importing(_, let unsupported) = mode {
                existing = nil
                unsupportedImportSettings = unsupported
                isImport = true
            } else {
                existing = profile
                unsupportedImportSettings = []
                isImport = false
            }
            base = profile.configuration.rdp
            displayName = profile.displayName
            host = profile.endpoint.host
            portText = String(profile.endpoint.port)
            username = profile.account.username ?? ""
            domain = profile.account.domain ?? ""
            let rdp = profile.configuration.rdp ?? RDPConfiguration()
            group = profile.group ?? ""
            isFavorite = profile.isFavorite
            redirectsMicrophone = rdp.redirectsMicrophone
            usesH264 = rdp.prefersH264
            remotePlatform = rdp.remotePlatform
            streamQuality = rdp.preferredStreamQuality
            remoteProgram = rdp.remoteApp?.program ?? ""
            remoteArguments = rdp.remoteApp?.arguments ?? ""
            if let wake = profile.wakeOnLAN {
                wakesOnLAN = true
                macAddress = wake.macAddress
                wakeTarget = wake.targetAddress
                wakePortText = String(wake.port)
                wakesBeforeConnecting = wake.wakesBeforeConnecting
            }
            keyboardLayout = rdp.keyboardLayout
            securityPolicy = rdp.securityPolicy
            audioPlayback = rdp.audioPlayback
            clipboardPolicy = rdp.clipboardPolicy
            scrollDirection = rdp.scrollDirection
            resolutionPolicy = rdp.resolutionPolicy
            if let gateway = rdp.gateway {
                usesGateway = true
                gatewayHost = gateway.host
                gatewayPortText = String(gateway.port)
                gatewayUsesComputerCredentials = gateway.usesComputerCredentials
                gatewayUsername = gateway.account.username ?? ""
                gatewayDomain = gateway.account.domain ?? ""
                gatewayBypassesLocal = gateway.bypassesLocalAddresses
            }
            if let folder = rdp.sharedFolder {
                switch folder.location {
                case .appDocuments: sharedFolder = .appDocuments
                case let .bookmark(data, name): sharedFolder = .picked(bookmark: data, name: name)
                }
                driveName = folder.driveName
            }
        }
        self.password = password ?? ""
    }

    var isEditing: Bool { existing != nil }

    var title: String {
        isEditing ? String(localized: "接続先を編集")
            : isImport ? String(localized: "接続先を読み込む") : String(localized: "接続先を追加")
    }

    var port: UInt16? {
        guard let value = UInt16(portText.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }
        return value
    }

    var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }

    var gatewayPort: UInt16? {
        guard let value = UInt16(gatewayPortText.trimmingCharacters(in: .whitespaces)), value > 0 else {
            return nil
        }
        return value
    }

    var trimmedGatewayHost: String { gatewayHost.trimmingCharacters(in: .whitespaces) }

    var isWakeValid: Bool {
        !wakesOnLAN || (MagicPacket.macBytes(macAddress) != nil && UInt16(wakePortText) != nil
            && !wakeTarget.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var isValid: Bool {
        !trimmedHost.isEmpty && port != nil
            && (!usesGateway || (!trimmedGatewayHost.isEmpty && gatewayPort != nil))
            && isWakeValid
    }

    /// The Eisu/Kana promise only holds for the Japanese layout, so the form
    /// says where it does not rather than silently mapping the keys anyway.
    var showsJapaneseKeyWarning: Bool {
        if case .explicit(let layout) = keyboardLayout, layout != .japanese { return true }
        return false
    }

    var showsLegacySecurityWarning: Bool { securityPolicy == .legacyExplicit }

    /// docs/data-and-security.md section 4: legacy RDP Security only by
    /// explicit consent. Choosing it in the picker only asks; the policy
    /// changes when the user confirms.
    var isConfirmingLegacySecurity = false

    func choose(_ policy: SecurityPolicy) {
        if policy == .legacyExplicit, securityPolicy != .legacyExplicit {
            isConfirmingLegacySecurity = true
        } else {
            securityPolicy = policy
        }
    }

    func confirmLegacySecurity() {
        isConfirmingLegacySecurity = false
        securityPolicy = .legacyExplicit
    }

    func declineLegacySecurity() {
        isConfirmingLegacySecurity = false
    }

    /// A name is optional in the form; falling back to the host is friendlier
    /// than refusing to save.
    var resolvedDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? trimmedHost : trimmed
    }

    func makeProfile(now: Date = Date()) -> ConnectionProfile? {
        guard let port else { return nil }
        // Built on what was there, so a field the form does not show is
        // kept rather than reset to inherit.
        var configuration = existing?.configuration.rdp ?? base ?? RDPConfiguration()
        configuration.keyboardLayout = keyboardLayout
        configuration.audioPlayback = audioPlayback
        configuration.clipboardPolicy = clipboardPolicy
        configuration.scrollDirection = scrollDirection
        configuration.resolutionPolicy = resolutionPolicy
        configuration.securityPolicy = securityPolicy
        if usesGateway, let gatewayPort {
            var gateway = configuration.gateway ?? RDPGatewayConfiguration(host: trimmedGatewayHost)
            gateway.host = trimmedGatewayHost
            gateway.port = gatewayPort
            gateway.usesComputerCredentials = gatewayUsesComputerCredentials
            gateway.account.username = gatewayUsername.isEmpty ? nil : gatewayUsername
            gateway.account.domain = gatewayDomain.isEmpty ? nil : gatewayDomain
            gateway.bypassesLocalAddresses = gatewayBypassesLocal
            configuration.gateway = gateway
        } else {
            configuration.gateway = nil
        }
        configuration.microphone = redirectsMicrophone ? true : nil
        configuration.usesH264 = usesH264 ? nil : false
        configuration.platform = remotePlatform == .standard ? nil : remotePlatform
        configuration.streamQuality = remotePlatform == .macOS && streamQuality != .automatic
            ? streamQuality : nil
        let program = remoteProgram.trimmingCharacters(in: .whitespaces)
        configuration.remoteApp = program.isEmpty
            ? nil
            : RemoteAppConfiguration(program: program, arguments: remoteArguments.trimmingCharacters(in: .whitespaces))
        switch sharedFolder {
        case .none:
            configuration.sharedFolder = nil
        case .appDocuments:
            configuration.sharedFolder = SharedFolder(location: .appDocuments, driveName: driveName)
        case let .picked(bookmark, name):
            configuration.sharedFolder = SharedFolder(
                location: .bookmark(bookmark, displayName: name),
                driveName: driveName
            )
        }
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
        profile.group = group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : group
        profile.isFavorite = isFavorite
        profile.wakeOnLAN = wakesOnLAN
            ? WakeOnLANConfiguration(
                macAddress: macAddress.trimmingCharacters(in: .whitespaces),
                targetAddress: wakeTarget.trimmingCharacters(in: .whitespaces),
                port: UInt16(wakePortText) ?? WakeOnLANConfiguration.defaultPort,
                wakesBeforeConnecting: wakesBeforeConnecting
            )
            : nil
        profile.updatedAt = now
        return profile
    }
}
