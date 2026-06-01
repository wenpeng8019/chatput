import AppKit
import Combine

/// 桌面端单一会话（= 一个被聚焦的输入窗口）。
struct FocusSession: Identifiable, Equatable {
    let id: String      // sessionId，与手机端一致：app|title
    let app: String
    let title: String
    let ts: Double
}

/// 全局可观察状态，驱动 SwiftUI 界面。所有更新都在主线程。
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published var status: String = "启动中…"
    /// 状态的中英文原文，用于切换语言时即时重新翻译。
    @Published var statusZh: String = "启动中…"
    @Published var statusEn: String = "Starting…"
    @Published var connected: Bool = false
    @Published var roomCode: String = ""
    @Published var qrImage: NSImage? = nil
    @Published var accessibilityGranted: Bool = false
    @Published var sessions: [FocusSession] = []
    @Published var logLines: [String] = []

    /// 内置信令服务器是否正在运行（仅本地内置模式有意义）。
    @Published var serverRunning: Bool = false
    /// 内置信令服务器实际监听端口。
    @Published var serverPort: UInt16 = 0
    /// 当前写入二维码、供手机连接的地址。
    @Published var advertisedURL: String = ""
    /// 用户是否希望服务处于运行状态（启停开关）。
    @Published var serviceActive: Bool = false
    /// 当前已连接手机的设备名（空表示未知或未连接）。
    @Published var connectedDevice: String = ""

    private init() {}

    func setConnectedDevice(_ name: String) {
        DispatchQueue.main.async { self.connectedDevice = name }
    }

    func setServiceActive(_ active: Bool) {
        DispatchQueue.main.async { self.serviceActive = active }
    }

    func setServerState(running: Bool, port: UInt16) {
        DispatchQueue.main.async {
            self.serverRunning = running
            self.serverPort = port
        }
    }

    func setStatus(_ text: String, connected: Bool) {
        DispatchQueue.main.async {
            self.status = text
            self.statusZh = text
            self.statusEn = text
            self.connected = connected
        }
    }

    /// 以中英文原文设置状态，渲染时按当前语言翻译（见 `statusText`）。
    func setStatus(zh: String, en: String, connected: Bool) {
        DispatchQueue.main.async {
            self.statusZh = zh
            self.statusEn = en
            self.status = L.t(zh, en)
            self.connected = connected
        }
    }

    /// 当前语言下的状态文案。
    var statusText: String { L.t(statusZh, statusEn) }

    func log(_ items: Any...) {
        let line = items.map { "\($0)" }.joined(separator: " ")
        DispatchQueue.main.async {
            self.logLines.append(line)
            if self.logLines.count > AppConfig.Limit.logLines {
                self.logLines.removeFirst(self.logLines.count - AppConfig.Limit.logLines)
            }
            NSLog("[chatput] %@", line)
        }
    }

    func upsertSession(_ s: FocusSession) {
        DispatchQueue.main.async {
            if !self.sessions.contains(where: { $0.id == s.id }) {
                self.sessions.insert(s, at: 0)
                if self.sessions.count > AppConfig.Limit.sessions { self.sessions.removeLast() }
            }
        }
    }
}
