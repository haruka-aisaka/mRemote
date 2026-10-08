import SwiftUI
import UIKit

/// What a connected monitor shows while a session is open.
enum ExternalDisplayMode: String, CaseIterable {
    /// The system's own mirroring of this screen.
    case mirror
    /// The remote desktop, at the monitor's size; this device becomes the
    /// keyboard and trackpad.
    case desktop
    /// The desktop spread over both screens: this device's on the left, the
    /// monitor's on the right.
    case extend

    static let storageKey = "external-display-mode"
}

/// The monitor, when one is connected, and the app's link to it.
@MainActor
@Observable
final class ExternalDisplayCoordinator {
    static let shared = ExternalDisplayCoordinator()

    /// The monitor's size in points and its scale, while one is connected.
    private(set) var screen: (size: CGSize, scale: CGFloat)?
    /// The session the monitor shows, set by the workspace on screen.
    var mirror: DesktopMirror?

    #if DEBUG
    /// A stand-in monitor drawn in a corner of this screen, for the
    /// Simulator, which cannot connect one: -mremote-fake-external-display.
    let isFaked = ProcessInfo.processInfo.arguments.contains("-mremote-fake-external-display")
    #else
    let isFaked = false
    #endif

    private init() {
        if isFaked {
            screen = (CGSize(width: 1280, height: 720), 1)
        }
    }

    func connected(size: CGSize, scale: CGFloat) {
        screen = (size, scale)
    }

    func disconnected() {
        screen = isFaked ? (CGSize(width: 1280, height: 720), 1) : nil
    }

    /// The monitor's size in pixels, which is what the desktop on it is
    /// asked to be.
    var pixelSize: (width: Int, height: Int)? {
        guard let screen else { return nil }
        // Even widths only: the display channel refuses odd ones.
        let width = Int((screen.size.width * screen.scale).rounded()) & ~1
        return (width, Int((screen.size.height * screen.scale).rounded()))
    }
}

/// Hands a monitor's scene its own delegate; every other scene is SwiftUI's.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        if connectingSceneSession.role == .windowExternalDisplayNonInteractive {
            let configuration = UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = ExternalDisplaySceneDelegate.self
            return configuration
        }
        return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    }
}

/// The monitor's window. It is created only while there is a desktop to put
/// on it; without one the system mirrors this screen as usual.
final class ExternalDisplaySceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        MainActor.assumeIsolated {
            let coordinator = ExternalDisplayCoordinator.shared
            coordinator.connected(size: scene.screen.bounds.size, scale: scene.screen.scale)
            let window = UIWindow(windowScene: scene)
            window.rootViewController = UIHostingController(rootView: ExternalDisplayRoot())
            window.backgroundColor = .black
            self.window = window
            update()
            observe()
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        didUpdateEffectiveGeometry previousEffectiveGeometry: UIWindowScene.Geometry
    ) {
        MainActor.assumeIsolated {
            ExternalDisplayCoordinator.shared.connected(
                size: windowScene.screen.bounds.size,
                scale: windowScene.screen.scale
            )
        }
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        MainActor.assumeIsolated {
            ExternalDisplayCoordinator.shared.disconnected()
            window = nil
        }
    }

    /// Shown while a session hands the monitor a desktop, hidden otherwise
    /// so the system's mirroring comes back.
    @MainActor
    private func update() {
        let hasDesktop = ExternalDisplayCoordinator.shared.mirror != nil
        if hasDesktop {
            window?.makeKeyAndVisible()
        }
        window?.isHidden = !hasDesktop
    }

    @MainActor
    private func observe() {
        withObservationTracking {
            _ = ExternalDisplayCoordinator.shared.mirror
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }
}

/// What the monitor shows: the session's desktop, edge to edge.
struct ExternalDisplayRoot: View {
    private let coordinator = ExternalDisplayCoordinator.shared

    var body: some View {
        ZStack {
            Color.black
            if let mirror = coordinator.mirror {
                DesktopMirrorSurface(mirror: mirror)
                    .id(ObjectIdentifier(mirror))
            }
        }
        .ignoresSafeArea()
    }
}
