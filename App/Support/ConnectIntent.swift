import AppIntents
import Foundation
import Persistence
import SessionCore

/// A saved connection as the Shortcuts app sees it: a name to pick, nothing
/// about the host or the account.
struct ConnectionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "接続先"
    static let defaultQuery = ConnectionQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ConnectionQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [ConnectionEntity] {
        try await Self.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ConnectionEntity] {
        try await Self.all()
    }

    /// Read from the file the app keeps them in, so the list is there
    /// without the app on screen.
    private static func all() async throws -> [ConnectionEntity] {
        let store = FileProfileStore(url: try FileProfileStore.defaultURL())
        return try await store.load().profiles.map { ConnectionEntity(id: $0.id.rawValue, name: $0.displayName) }
    }
}

/// Shortcuts > mRemote > 接続: opens the app on that connection, or on its
/// running session.
struct ConnectIntent: AppIntent {
    static let title: LocalizedStringResource = "接続先に接続"
    static let description = IntentDescription("保存した接続先に接続します。接続中ならその画面を開きます。")
    static let openAppWhenRun = true

    @Parameter(title: "接続先")
    var connection: ConnectionEntity

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$connection) に接続")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        IntentRouter.request(URL(string: "mremote://connect?profile=\(connection.id.uuidString)")!)
        return .result()
    }
}

struct MRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectIntent(),
            phrases: [
                "Connect with \(.applicationName)",
                "\(.applicationName) で接続",
            ],
            shortTitle: "接続",
            systemImageName: "desktopcomputer"
        )
    }
}

/// Hands an intent's request to the running app, or keeps it until the app
/// has its environment.
@MainActor
enum IntentRouter {
    private static weak var environment: AppEnvironment?
    private static var pending: URL?

    static func attach(_ environment: AppEnvironment) {
        self.environment = environment
        if let url = pending {
            pending = nil
            Task { await environment.open(url) }
        }
    }

    static func request(_ url: URL) {
        if let environment {
            Task { await environment.open(url) }
        } else {
            pending = url
        }
    }
}
