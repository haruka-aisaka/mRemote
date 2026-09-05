import Foundation
import Observation
import SwiftUI
import AppleAdapters
import Persistence
import SessionCore

/// Composition root. Everything the screens need is assembled here, so no view
/// constructs a repository or a session of its own and a UI test can swap the
/// whole graph for an in-memory one.
@MainActor
@Observable
final class AppEnvironment {
    let credentials: any CredentialRepository
    let trust: any TrustRepository
    let sessions: SessionManager
    let factories: SessionFactoryRegistry

    private let store: any ProfileStore
    private(set) var repository: ProfileRepository?
    private(set) var profiles: [ConnectionProfile] = []
    private(set) var globalSettings: GlobalSettings = .default
    private(set) var loadFailure: String?

    var presentedSession: SessionWorkspaceModel?
    /// Sessions that are still connected while the user is back on the list.
    /// SES-02 keeps a foreground connection alive until an explicit
    /// disconnect, so without this they would be running with no way back to
    /// them.
    private(set) var runningSessions: [SessionWorkspaceModel] = []

    private let logger = AppLog.logger(.app)

    init(
        store: any ProfileStore,
        credentials: any CredentialRepository,
        trust: any TrustRepository,
        factories: SessionFactoryRegistry
    ) {
        self.store = store
        self.credentials = credentials
        self.trust = trust
        self.factories = factories
        self.sessions = SessionManager()
    }

    /// The shipping graph. The only place that knows RDP exists: everything
    /// above asks the registry for a session by protocol kind, so Phase 8's
    /// SSH session is one more registration here.
    static func live() -> AppEnvironment {
        if UITestConfiguration.isActive {
            return UITestConfiguration.makeEnvironment()
        }
        let store: any ProfileStore
        do {
            store = FileProfileStore(url: try FileProfileStore.defaultURL())
        } catch {
            // A store that cannot be located is reported on screen rather than
            // silently replaced by an in-memory one, which would look like the
            // user's profiles had vanished.
            store = FailingProfileStore(reason: String(describing: error))
        }
        let credentials = KeychainCredentialRepository()
        let trust = KeychainTrustRepository()
        return AppEnvironment(
            store: store,
            credentials: credentials,
            trust: trust,
            factories: SessionFactoryRegistry(factories: [
                RDPSessionFactory(credentials: credentials, trust: trust)
            ])
        )
    }

    func start() async {
        do {
            let repository = try await ProfileRepository(store: store)
            self.repository = repository
            await refresh()
        } catch {
            loadFailure = String(describing: error)
            logger.error("profile store load failed")
        }
    }

    func refresh() async {
        guard let repository else { return }
        profiles = await repository.profiles
        globalSettings = await repository.globalSettings
    }

    func save(_ profile: ConnectionProfile, password: String?) async {
        guard let repository else { return }
        var profile = profile
        do {
            if let password, !password.isEmpty {
                // A new password gets a fresh reference only when the profile
                // does not already have one, so rotating a password does not
                // orphan the previous Keychain item.
                let reference = profile.account.credentialReference ?? CredentialReference()
                try credentials.store(password: password, for: reference)
                profile.account.credentialReference = reference
            }
            try await repository.upsert(profile)
            await refresh()
        } catch {
            loadFailure = String(describing: error)
            logger.error("saving a profile failed")
        }
    }

    func delete(_ profile: ConnectionProfile) async {
        guard let repository else { return }
        do {
            if let orphaned = try await repository.delete(id: profile.id) {
                // Only deleted once no remaining profile references it.
                try credentials.delete(orphaned)
            }
            await refresh()
        } catch {
            loadFailure = String(describing: error)
            logger.error("deleting a profile failed")
        }
    }

    func duplicate(_ profile: ConnectionProfile) async {
        let copy = profile.duplicated(displayName: "\(profile.displayName) のコピー")
        await save(copy, password: nil)
    }

    func updateGlobalSettings(_ settings: GlobalSettings) async {
        guard let repository else { return }
        do {
            try await repository.updateGlobalSettings(settings)
            await refresh()
        } catch {
            loadFailure = String(describing: error)
        }
    }

    func storedPassword(for profile: ConnectionProfile) -> String? {
        guard let reference = profile.account.credentialReference else { return nil }
        return try? credentials.password(for: reference)
    }

    func connect(to profile: ConnectionProfile) async {
        guard let repository,
              let configuration = await repository.effectiveConfiguration(for: profile.id)
        else { return }

        do {
            let session = try await factories.makeSession(
                kind: profile.protocolKind,
                configuration: configuration
            )
            try await sessions.add(session)
            await sessions.applyVisibilityPolicy()
            try? await repository.markConnected(id: profile.id)
            await refresh()

            let model = SessionWorkspaceModel(
                environment: self,
                session: session,
                configuration: configuration
            )
            runningSessions.append(model)
            presentedSession = model
            await model.start()
        } catch let error as SessionBudgetExceededError {
            loadFailure = "同時接続はあと \(error.limit) セッションまでです。"
        } catch {
            loadFailure = String(describing: error)
        }
    }

    /// Called when the workspace closes. Removing the session frees its budget
    /// slot; focus moves to whatever is still connected.
    func endSession(_ id: SessionID) async {
        _ = await sessions.remove(id)
        await sessions.applyVisibilityPolicy()
        runningSessions.removeAll { $0.id == id }
        presentedSession = nil
    }

    func present(_ model: SessionWorkspaceModel) {
        presentedSession = model
    }
}

/// Stands in for a store that could not be located, so the failure surfaces
/// once at launch instead of on every save.
actor FailingProfileStore: ProfileStore {
    private let reason: String

    init(reason: String) {
        self.reason = reason
    }

    func load() throws -> ProfileDocument {
        throw StoreError.malformedDocument(detail: reason)
    }

    func save(_ document: ProfileDocument) throws {
        throw StoreError.malformedDocument(detail: reason)
    }
}
