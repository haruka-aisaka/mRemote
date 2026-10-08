import SwiftUI
import UIKit

/// The Mac window around a view: its title in the title bar and the Window
/// menu, and how small it may be dragged. Does nothing on an iPad, where a
/// scene's size is the system's to decide.
struct MacWindowConfigurator: UIViewRepresentable {
    var title: String?
    var minimumSize: CGSize?

    func makeUIView(context: Context) -> UIView {
        let view = ConfiguringView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let view = view as? ConfiguringView else { return }
        view.title = title
        view.minimumSize = minimumSize
        view.apply()
    }

    final class ConfiguringView: UIView {
        var title: String?
        var minimumSize: CGSize?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            apply()
        }

        func apply() {
            guard Platform.isMac, let scene = window?.windowScene else { return }
            if let title { scene.title = title }
            if let minimumSize { scene.sizeRestrictions?.minimumSize = minimumSize }
        }
    }
}

extension View {
    func macWindow(title: String? = nil, minimumSize: CGSize? = nil) -> some View {
        background(
            MacWindowConfigurator(title: title, minimumSize: minimumSize)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
    }
}
