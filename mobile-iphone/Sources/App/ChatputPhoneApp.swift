import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    let connections = ConnectionManager()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let w = ThemeWindow(frame: UIScreen.main.bounds)
        let home = HomeViewController(connections: connections)
        let nav = UINavigationController(rootViewController: home)
        nav.setNavigationBarHidden(true, animated: false)
        w.rootViewController = nav
        w.makeKeyAndVisible()
        window = w
        return true
    }
}

extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

/// Window that forces layer refresh when light/dark mode changes.
final class ThemeWindow: UIWindow {
    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard traitCollection.hasDifferentColorAppearance(comparedTo: previous) else { return }
        // Iterate all windows to re-resolve dynamic layer colors
        for window in UIApplication.shared.windows {
            window.reloadInputViews()
            window.rootViewController?.view.setNeedsLayout()
            window.rootViewController?.view.layoutIfNeeded()
        }
    }
}
