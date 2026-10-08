import UIKit

/// How a foldable's screen turns while it is half folded.
enum FoldedOrientation: String, CaseIterable {
    /// Upright above the hinge, the laptop posture, however it is held.
    case laptop
    /// Whichever way it is held: sideways too, folded a little like a book.
    case free

    static let storageKey = "folded-orientation"
}

/// The orientations the app allows right now. UIKit asks the app delegate;
/// the workspace narrows it while a foldable is folded.
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask?

    static var supported: UIInterfaceOrientationMask {
        mask ?? (UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown)
    }

    /// Nil lets the device turn freely again.
    static func set(_ newMask: UIInterfaceOrientationMask?) {
        guard newMask != mask else { return }
        mask = newMask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            var controller = scene.keyWindow?.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: supported)) { _ in }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.supported
    }
}
