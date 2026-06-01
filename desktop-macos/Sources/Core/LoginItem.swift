import Foundation
import ServiceManagement

/// 开机自启动管理。
/// macOS 13+ 用 `SMAppService`；更早版本回退到写入 LaunchAgent plist。
enum LoginItem {
    private static var agentLabel: String {
        (Bundle.main.bundleIdentifier ?? "com.chatput.ChatputDesktop") + ".launchatlogin"
    }

    private static var agentPlistURL: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        return dir.appendingPathComponent("\(agentLabel).plist")
    }

    /// 当前是否已启用开机自启。
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return FileManager.default.fileExists(atPath: agentPlistURL.path)
        }
    }

    /// 设置开机自启开关。
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else {
                    if SMAppService.mainApp.status == .enabled {
                        try SMAppService.mainApp.unregister()
                    }
                }
                return true
            } catch {
                NSLog("LoginItem error: \(error)")
                return false
            }
        } else {
            return enabled ? writeAgent() : removeAgent()
        }
    }

    // MARK: - macOS 12 回退：LaunchAgent plist

    private static func writeAgent() -> Bool {
        guard let exec = Bundle.main.executablePath else { return false }
        let plist: [String: Any] = [
            "Label": agentLabel,
            "ProgramArguments": [exec],
            "RunAtLoad": true,
        ]
        do {
            try FileManager.default.createDirectory(
                at: agentPlistURL.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentPlistURL)
            return true
        } catch {
            NSLog("LoginItem writeAgent error: \(error)")
            return false
        }
    }

    private static func removeAgent() -> Bool {
        guard FileManager.default.fileExists(atPath: agentPlistURL.path) else { return true }
        do {
            try FileManager.default.removeItem(at: agentPlistURL)
            return true
        } catch {
            NSLog("LoginItem removeAgent error: \(error)")
            return false
        }
    }
}
