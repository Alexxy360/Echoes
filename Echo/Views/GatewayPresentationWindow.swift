#if DEBUG
    import SwiftUI
    import UIKit

    @MainActor final class GatewayPresentationWindow {
        weak var view: UIView?
        var window: UIWindow? { view?.window }
    }
    /// Tracks the feature's window even after the sign-in button disappears or navigation changes.
    struct GatewayWindowReader: UIViewRepresentable {
        let anchor: GatewayPresentationWindow
        func makeUIView(context: Context) -> UIView {
            let view = UIView()
            view.isUserInteractionEnabled = false
            anchor.view = view
            return view
        }
        func updateUIView(_ view: UIView, context: Context) { anchor.view = view }
    }
#endif
