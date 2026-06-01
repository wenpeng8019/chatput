import AppKit
import ApplicationServices

/// 用 AXObserver 精准监控焦点变化（替代 active-win 轮询）。
/// 监听应用切换 + 每个应用内部的「聚焦窗口/聚焦元素」变化，焦点变了就回调一个会话。
final class FocusMonitor {
    var onSession: ((FocusSession) -> Void)?

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var lastKey = ""
    private var monitoring = false
    private var ownBundleId = Bundle.main.bundleIdentifier ?? ""

    private let notifications: [String] = [
        kAXFocusedUIElementChangedNotification,
        kAXFocusedWindowChangedNotification,
        kAXMainWindowChangedNotification,
        kAXTitleChangedNotification,
    ]

    func start() {
        guard !monitoring else { emitCurrent(); return }
        monitoring = true
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(self,
                       selector: #selector(activeAppChanged(_:)),
                       name: NSWorkspace.didActivateApplicationNotification,
                       object: nil)
        if let app = NSWorkspace.shared.frontmostApplication {
            attach(to: app)
        }
    }

    /// 强制重新发出当前焦点会话（忽略去重）。
    /// 用于 DataChannel 刚建立时补发——首次连通瞬间通道可能尚未 open，首个会话会被丢弃。
    func resendCurrent() {
        lastKey = ""
        emitCurrent()
    }

    @objc private func activeAppChanged(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        attach(to: app)
    }

    // MARK: - AXObserver 绑定到当前前台应用

    private func attach(to app: NSRunningApplication) {
        guard app.bundleIdentifier != ownBundleId else { return }
        let pid = app.processIdentifier
        if pid == observedPID { emitCurrent(); return }

        detach()
        observedPID = pid

        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon = refcon else { return }
            let monitor = Unmanaged<FocusMonitor>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { monitor.emitCurrent() }
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs = obs else {
            // 没权限或失败也至少发一次当前会话。
            emitCurrent()
            return
        }
        observer = obs

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for name in notifications {
            AXObserverAddNotification(obs, appElement, name as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)

        emitCurrent()
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        observer = nil
        observedPID = 0
    }

    // MARK: - 读取当前焦点并发出会话

    private func emitCurrent() {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != ownBundleId else { return }

        let appName = app.localizedName ?? "Unknown"
        let title = focusedWindowTitle(pid: app.processIdentifier)
        let key = "\(appName)|\(title)"
        guard key != lastKey else { return }
        lastKey = key

        onSession?(FocusSession(id: key, app: appName, title: title, ts: Date().timeIntervalSince1970 * 1000))
    }

    private func focusedWindowTitle(pid: pid_t) -> String {
        let appElement = AXUIElementCreateApplication(pid)
        var winRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &winRef)
        guard err == .success, let winRef = winRef else { return "" }

        // CFTypeRef 实际为 AXUIElement。
        let window = winRef as! AXUIElement
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String {
            return title
        }
        return ""
    }

    deinit {
        detach()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
