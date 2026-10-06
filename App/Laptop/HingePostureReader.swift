import SwiftUI
import UIKit

/// Whether the device is a foldable bent part-way open.
///
/// iOS 27.1 reports a hinge's status and angle but not where it is. On the
/// iPhone Duo the inner display folds across its long side, through the
/// middle - the cover display is the size of one half - so a half-open hinge
/// with the screen taller than wide is the laptop posture: one half stands
/// up, the other lies flat in front of the user.
enum HingePosture: Equatable {
    /// No hinge, or the scene is not on a display that has one.
    case unavailable
    case closed
    case partiallyOpen
    case fullyOpen
}

/// Reads the hinge through `UIHingeInteraction`, which, unlike SwiftUI's
/// `onHingeChange`, also delivers the state the view starts in.
///
/// Built against an SDK without hinge APIs - anything before Xcode 27.1 -
/// this always reports `.unavailable`, so the rest of the app needs no
/// conditional compilation of its own.
struct HingePostureReader: UIViewRepresentable {
    let onChange: (HingePosture) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        #if canImport(UIKit, _version: 9127.0.85)
        if #available(iOS 27.1, *) {
            let report = context.coordinator
            view.addInteraction(UIHingeInteraction { _, update in
                report.onChange(Self.posture(update.hinge))
            })
        }
        #endif
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onChange = onChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onChange: onChange)
    }

    /// Holds the latest closure, so the interaction - created once - always
    /// reports to the view as it is now.
    @MainActor
    final class Coordinator {
        var onChange: (HingePosture) -> Void

        init(onChange: @escaping (HingePosture) -> Void) {
            self.onChange = onChange
        }
    }

    #if canImport(UIKit, _version: 9127.0.85)
    @available(iOS 27.1, *)
    private static func posture(_ hinge: UIHinge?) -> HingePosture {
        guard let hinge else { return .unavailable }
        switch hinge.status {
        case .closed: return .closed
        case .partiallyOpen: return .partiallyOpen
        case .fullyOpen: return .fullyOpen
        default: return .unavailable
        }
    }
    #endif
}
