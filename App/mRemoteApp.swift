import SwiftUI

@main
struct mRemoteApp: App {
    /// Only for a monitor's scene, which SwiftUI does not create.
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment = AppEnvironment.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
                .task {
                    IntentRouter.attach(environment)
                    await environment.start()
                }
                // .rdp files, rdp:// links and the Shortcuts app's
                // mremote://connect.
                .onOpenURL { url in Task { await environment.open(url) } }
        }
        // iPad: a session in a window of its own.
        WindowGroup("セッション", id: "session", for: UUID.self) { $profileID in
            SessionWindowRoot(profileID: profileID)
                .environment(environment)
        }
        // docs/architecture.md section 10: no audio from the background.
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: AudioCoordinator.shared.suspend()
            case .active: AudioCoordinator.shared.resume()
            default: break
            }
        }
    }
}

/// The app is one window with two levels: the connection list, and a
/// full-screen session on top of it. docs/ui-flow.md keeps the session
/// full-screen with a floating menu rather than a navigation bar, so nothing
/// competes with the remote desktop for space.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ConnectionListView()
            // Presented by a flag rather than by item, so switching sessions
            // swaps the content in place instead of dismissing and presenting
            // a second cover. `.id` rebuilds the surface per session: each
            // one draws a different frame store.
            .fullScreenCover(isPresented: Binding(
                get: { environment.presentedSession != nil },
                set: { if !$0 { environment.returnToList() } }
            )) {
                if let session = environment.presentedSession {
                    SessionWorkspaceView(model: session)
                        .id(session.id)
                        .environment(environment)
                }
            }
            // With several windows, the one in front decides what types:
            // this one's session, or nothing while the list is up.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active, UIApplication.shared.supportsMultipleScenes else { return }
                Task { await environment.focus(environment.presentedSession?.id) }
            }
    }
}
