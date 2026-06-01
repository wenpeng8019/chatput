import SwiftUI

@main
struct ChatputDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(state)
                .frame(minWidth: 360, minHeight: 520)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = Coordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 请求辅助功能权限（AXObserver 监控焦点 + CGEvent 注入都需要）。
        TextInjector.ensureAccessibilityPermission(prompt: true)
        coordinator.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
