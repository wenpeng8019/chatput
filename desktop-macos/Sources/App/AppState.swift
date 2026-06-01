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
    @Published var connected: Bool = false
    @Published var roomCode: String = ""
    @Published var qrImage: NSImage? = nil
    @Published var accessibilityGranted: Bool = false
    @Published var sessions: [FocusSession] = []
    @Published var logLines: [String] = []

    private init() {}

    func setStatus(_ text: String, connected: Bool) {
        DispatchQueue.main.async {
            self.status = text
            self.connected = connected
        }
    }

    func log(_ items: Any...) {
        let line = items.map { "\($0)" }.joined(separator: " ")
        DispatchQueue.main.async {
            self.logLines.append(line)
            if self.logLines.count > 200 { self.logLines.removeFirst(self.logLines.count - 200) }
            NSLog("[remote-input] %@", line)
        }
    }

    func upsertSession(_ s: FocusSession) {
        DispatchQueue.main.async {
            if !self.sessions.contains(where: { $0.id == s.id }) {
                self.sessions.insert(s, at: 0)
                if self.sessions.count > 30 { self.sessions.removeLast() }
            }
        }
    }
}
