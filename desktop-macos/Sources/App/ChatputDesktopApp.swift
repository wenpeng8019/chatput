import SwiftUI
import AppKit
import Combine

@main
struct ChatputDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 纯菜单栏应用：无主窗口。设置场景留空，避免出现窗口。
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let coordinator = Coordinator.shared
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 请求辅助功能权限（AXObserver 监控焦点 + CGEvent 注入都需要）。
        TextInjector.ensureAccessibilityPermission(prompt: true)

        setupStatusItem()
        setupPopover()
        coordinator.start()

        // 语言变更时实时更新设置窗口标题。
        AppSettings.shared.$language
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.settingsWindow?.title = L.t("ChatPUT · 设置", "ChatPUT · Settings")
            }
            .store(in: &cancellables)
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(named: "MenuBarIcon")
                ?? NSImage(systemSymbolName: "keyboard.badge.waveform",
                           accessibilityDescription: "ChatPUT")
                ?? NSImage(systemSymbolName: "keyboard", accessibilityDescription: "ChatPUT")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
    }

    private func setupPopover() {
        popover.behavior = .transient
        popover.animates = true
        // 让内容按 SwiftUI 固有尺寸自适应，避免出现滚动条。
        let host = NSHostingController(
            rootView: ContentView(onOpenSettings: { [weak self] in self?.openSettings() })
                .environmentObject(AppState.shared)
        )
        if #available(macOS 13.0, *) {
            host.sizingOptions = [.preferredContentSize]
        }
        popover.contentViewController = host
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    // MARK: - 设置窗口

    private func openSettings() {
        popover.performClose(nil)

        if let window = settingsWindow {
            window.title = L.t("ChatPUT · 设置", "ChatPUT · Settings")
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let host = NSHostingController(
            rootView: SettingsView(onClose: { [weak self] in
                self?.settingsWindow?.performClose(nil)
                DispatchQueue.main.async { self?.showPopover() }
            })
        )
        let window = NSWindow(contentViewController: host)
        window.title = L.t("ChatPUT · 设置", "ChatPUT · Settings")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
