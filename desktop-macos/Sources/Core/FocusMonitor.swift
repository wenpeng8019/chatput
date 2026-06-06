import AppKit
import ApplicationServices

/// 用 AXObserver 精准监控焦点变化（替代 active-win 轮询）。
/// 监听应用切换 + 每个应用内部的「聚焦窗口/聚焦元素」变化，焦点变了就回调一个会话。
final class FocusMonitor {
    var onSession: ((FocusSession) -> Void)?
    var onSessionClosed: ((String) -> Void)?
    /// 窗口仍在但输入控件暂时不可用时回调（与 session-closed 互斥）。
    var onSessionInputLost: ((String) -> Void)?

    private var observer: AXObserver?
    private var observedPID: pid_t = 0
    private var lastKey = ""
    private var monitoring = false
    private var ownBundleId = Bundle.main.bundleIdentifier ?? ""
    private let finderBundleId = "com.apple.finder"
    private var knownSessions: [String: String] = [:] // sessionId -> appName
    private var windowExistenceTimer: Timer?
    /** 已发过 input-lost 的 session，避免轮询时重复发。 */
    private var pendingInputLost: Set<String> = []

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
        startWindowExistencePolling()
    }

    /// 强制重新发出当前焦点会话（忽略去重）。
    /// 用于 DataChannel 刚建立时补发——首次连通瞬间通道可能尚未 open，首个会话会被丢弃。
    func resendCurrent() {
        lastKey = ""
        emitCurrent()
    }

    /// 已在监控时补发当前焦点；未启动时先启动再等待后续变化。
    func ensureCurrentDelivered() {
        if monitoring {
            resendCurrent()
        } else {
            start()
        }
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
        if app.bundleIdentifier == finderBundleId && title.isEmpty {
            // 点击系统桌面时前台应用会变成 Finder，但它不是一个可输入目标。
            return
        }
        let key = "\(appName)|\(title)"
        guard key != lastKey else { return }
        lastKey = key

        onSession?(FocusSession(id: key, app: appName, title: title, ts: Date().timeIntervalSince1970 * 1000))
        knownSessions[key] = appName
        pendingInputLost.remove(key)
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

    // MARK: - 窗口关闭检测

    private func startWindowExistencePolling() {
        windowExistenceTimer?.invalidate()
        let timer = Timer(timeInterval: AppConfig.Timing.windowExistencePoll, repeats: true) { [weak self] _ in
            self?.removeClosedKnownSessions()
        }
        RunLoop.main.add(timer, forMode: .common)
        windowExistenceTimer = timer
    }

    private func removeClosedKnownSessions() {
        guard !knownSessions.isEmpty else { return }

        var liveSessionIds = Set<String>()
        var readableApps = Set<String>()
        var runningApps = Set<String>()
        // appName → 该 app 当前是否有窗口
        var appHasWindows: [String: Bool] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  app.bundleIdentifier != ownBundleId,
                  let appName = app.localizedName else { continue }
            runningApps.insert(appName)

            guard let titles = windowTitles(pid: app.processIdentifier) else { continue }
            readableApps.insert(appName)
            appHasWindows[appName] = !titles.isEmpty
            titles.forEach { title in
                liveSessionIds.insert("\(appName)|\(title)")
            }
        }

        for (sessionId, appName) in knownSessions {
            let appStillRunning = runningApps.contains(appName)
            let canJudgeWindows = readableApps.contains(appName)
            let hasWindows = appHasWindows[appName] ?? false
            let titleGone = canJudgeWindows && !liveSessionIds.contains(sessionId)

            if !appStillRunning || (titleGone && !hasWindows) {
                // 窗口确实已关闭（app 退出或没有任何窗口了）。
                knownSessions.removeValue(forKey: sessionId)
                pendingInputLost.remove(sessionId)
                if lastKey == sessionId { lastKey = "" }
                onSessionClosed?(sessionId)
            } else if titleGone && hasWindows && !pendingInputLost.contains(sessionId) {
                // 窗口仍在但当前标题丢失 → input 暂时不可用，不关闭会话。
                NSLog("[chatput] input-lost: session=\(sessionId) titleGone=\(titleGone) hasWindows=\(hasWindows) canJudge=\(canJudgeWindows)")
                pendingInputLost.insert(sessionId)
                onSessionInputLost?(sessionId)
            }
        }

        // 检测已 lost 的 session 是否恢复：标题重新出现则重发 session 以恢复输入。
        for sessionId in pendingInputLost {
            if liveSessionIds.contains(sessionId) {
                pendingInputLost.remove(sessionId)
                if lastKey == sessionId { lastKey = "" }
                let parts = sessionId.split(separator: "|", maxSplits: 1).map(String.init)
                let appName = parts.first ?? ""
                let title = parts.count > 1 ? parts[1] : ""
                let session = FocusSession(id: sessionId, app: appName, title: title,
                                           ts: Date().timeIntervalSince1970 * 1000)
                knownSessions[sessionId] = appName
                onSession?(session)
                break
            }
        }
    }

    private func windowTitles(pid: pid_t) -> [String]? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
        guard err == .success else { return nil }
        guard let windows = windowsRef as? [AXUIElement] else { return [] }

        return windows.map { window in
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
               let title = titleRef as? String {
                return title
            }
            return ""
        }
    }

    deinit {
        windowExistenceTimer?.invalidate()
        detach()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
