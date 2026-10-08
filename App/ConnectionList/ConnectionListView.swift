import SwiftUI
import UniformTypeIdentifiers
import SessionCore

struct ConnectionListView: View {
    @Environment(AppEnvironment.self) private var environment
    /// One presentation state for both sheets. Two `.sheet` modifiers on the
    /// same view do not both work in SwiftUI -- the later one wins -- so the
    /// route is modelled once and presented once.
    @State private var route: Route?
    @State private var isImportingFile = false

    private enum Route: Identifiable {
        case editor(ProfileEditorModel)
        case settings

        var id: String {
            switch self {
            case .editor(let model): return "editor-\(model.id)"
            case .settings: return "settings"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let failure = environment.loadFailure {
                    ContentUnavailableView {
                        Label("接続先を読み込めません", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(failure)
                    }
                } else if environment.profiles.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("接続先")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        route = .settings
                    } label: {
                        Label("設定", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("settings-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isImportingFile = true
                    } label: {
                        Label(".rdp ファイルから読み込む", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("import-profile-button")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        route = .editor(ProfileEditorModel(mode: .create))
                    } label: {
                        Label("追加", systemImage: "plus")
                    }
                    .accessibilityIdentifier("add-profile-button")
                }
            }
        }
        // iPad shows a centred form sheet, iPhone a large sheet; the adaptive
        // presentation is what SwiftUI does by default for `.sheet`, so the
        // only thing worth stating is the detent for the compact case.
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [UTType(filenameExtension: "rdp") ?? .data]
        ) { result in
            guard case .success(let url) = result else { return }
            Task { await environment.open(url) }
        }
        .onChange(of: environment.pendingImport?.id, initial: true) { _, _ in
            guard let model = environment.pendingImport else { return }
            environment.pendingImport = nil
            route = .editor(model)
        }
        .alert(
            "読み込めませんでした",
            isPresented: Binding(
                get: { environment.importFailure != nil },
                set: { if !$0 { environment.importFailure = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(environment.importFailure ?? "")
        }
        .sheet(item: $route) { route in
            switch route {
            case .editor(let model):
                ProfileEditorView(model: model)
                    .presentationDetents([.large])
            case .settings:
                SettingsView()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("接続先がありません", systemImage: "desktopcomputer")
        } description: {
            Text("右上の + から Windows の接続先を追加します。")
        } actions: {
            Button("接続先を追加") {
                route = .editor(ProfileEditorModel(mode: .create))
            }
            .accessibilityIdentifier("empty-add-profile-button")
        }
        .accessibilityIdentifier("empty-state")
    }

    private var list: some View {
        List {
            if !environment.runningSessions.isEmpty {
                Section("実行中") {
                    ForEach(environment.runningSessions) { session in
                        Button {
                            environment.present(session)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.displayName).font(.headline)
                                        .foregroundStyle(.primary)
                                    SessionStateBadge(
                                        state: session.state,
                                        statusText: session.statusText
                                    )
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("running-session-\(session.displayName)")
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) {
                                Task { await session.disconnect() }
                            } label: {
                                Label(session.state.isActive ? String(localized: "切断") : String(localized: "閉じる"),
                                      systemImage: "xmark.circle")
                            }
                        }
                    }
                }
            }

            Section {
            ForEach(environment.profiles) { profile in
                Button {
                    // docs/ui-flow.md section 7: an ordinary tap returns to the
                    // profile's running session; only the explicit action
                    // below opens a second one.
                    if let running = environment.runningSession(for: profile) {
                        environment.present(running)
                    } else {
                        Task { await environment.connect(to: profile) }
                    }
                } label: {
                    ConnectionRow(profile: profile)
                }
                .accessibilityIdentifier("profile-row-\(profile.displayName)")
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) {
                        Task { await environment.delete(profile) }
                    } label: {
                        Label("削除", systemImage: "trash")
                    }
                    Button {
                        route = .editor(ProfileEditorModel(
                            mode: .edit(profile),
                            password: environment.storedPassword(for: profile)
                        ))
                    } label: {
                        Label("編集", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
                .contextMenu {
                    Button("新しいセッションで接続") {
                        Task { await environment.connect(to: profile) }
                    }
                    .accessibilityIdentifier("connect-new-session")
                    Button("編集") {
                        route = .editor(ProfileEditorModel(
                            mode: .edit(profile),
                            password: environment.storedPassword(for: profile)
                        ))
                    }
                    Button("複製") {
                        Task { await environment.duplicate(profile) }
                    }
                    Button("削除", role: .destructive) {
                        Task { await environment.delete(profile) }
                    }
                }
            }
            }
        }
        .accessibilityIdentifier("profile-list")
    }
}

private struct ConnectionRow: View {
    let profile: ConnectionProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(profile.displayName)
                .font(.headline)
                .foregroundStyle(.primary)
            Text(Formatting.subtitle(for: profile))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let last = Formatting.lastConnected(profile.lastConnectedAt) {
                Text("最終接続 \(last)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}
