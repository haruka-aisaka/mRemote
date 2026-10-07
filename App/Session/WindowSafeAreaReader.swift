import SwiftUI
import UIKit

/// The window's safe area - the Dynamic Island or notch, the rounded corners,
/// the home indicator - as the system reports it for this device and
/// rotation.
///
/// Read from UIKit because the workspace lays itself out edge to edge, and
/// below `ignoresSafeArea` SwiftUI reports the insets as zero.
struct WindowSafeAreaReader: UIViewRepresentable {
    let onChange: (EdgeInsets) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        view.report()
    }

    /// Laid out over the whole screen, so a rotation or a resize reaches it.
    final class ReaderView: UIView {
        var onChange: ((EdgeInsets) -> Void)?
        private var reported: UIEdgeInsets?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            report()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            report()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            report()
        }

        func report() {
            guard let window, window.safeAreaInsets != reported else { return }
            let insets = window.safeAreaInsets
            reported = insets
            let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
            let edges = EdgeInsets(
                top: insets.top,
                leading: rightToLeft ? insets.right : insets.left,
                bottom: insets.bottom,
                trailing: rightToLeft ? insets.left : insets.right
            )
            // Reported after the pass that noticed it, not during it: the
            // change re-lays out the SwiftUI views around this one.
            DispatchQueue.main.async { [weak self] in self?.onChange?(edges) }
        }
    }
}
