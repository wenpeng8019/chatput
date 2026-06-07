import SwiftUI
import UIKit

@main
struct ChatputPhoneApp: App {
    @StateObject private var connections = ConnectionManager()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(connections)
        }
    }
}

// 隐藏系统返回按钮后，SwiftUI 默认会一并禁用「左边缘右滑返回」手势。
// 这里把 interactivePopGestureRecognizer 的 delegate 交回，恢复边缘滑动返回（仅在有上级页面时生效）。
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}

