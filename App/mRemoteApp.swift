import SwiftUI

@main
struct mRemoteApp: App {
    @State private var environment = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task { await environment.start() }
        }
    }
}

/// The app is one window with two levels: the connection list, and a
/// full-screen session on top of it. docs/ui-flow.md keeps the session
/// full-screen with a floating menu rather than a navigation bar, so nothing
/// competes with the remote desktop for space.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ConnectionListView()
            .fullScreenCover(item: Binding(
                get: { environment.presentedSession },
                set: { if $0 == nil { environment.presentedSession = nil } }
            )) { session in
                SessionWorkspaceView(model: session)
            }
    }
}
