import Foundation
import CoreGraphics

/// 集中管理散落各处的"魔法数字"：时长、限制、按键码等。
/// 便于统一调优，避免同一含义的常量在多个文件里各写一份。
enum AppConfig {
    /// 各类时间间隔（秒）。
    enum Timing {
        /// 辅助功能授权状态轮询间隔。
        static let accessibilityPoll: TimeInterval = 1.5
        /// 信令断开后自动重连延迟。
        static let reconnectDelay: TimeInterval = 3
        /// 配置变更后重启链路前的缓冲延迟。
        static let restartDebounce: TimeInterval = 0.3
        /// 网络环境变化后的缓冲延迟，避免接口抖动时频繁重启。
        static let networkChangeDebounce: TimeInterval = 1.0
        /// 粘贴完成后还原剪贴板的延迟。
        static let clipboardRestore: TimeInterval = 0.3
    }

    /// 各类容量上限。
    enum Limit {
        /// 调试日志保留的最大行数。
        static let logLines = 200
        /// 会话列表保留的最大条目数。
        static let sessions = 30
    }

    /// macOS 虚拟按键码（virtual key codes）。
    enum KeyCode {
        static let v: CGKeyCode = 9
        static let a: CGKeyCode = 0
        static let `return`: CGKeyCode = 36
        static let delete: CGKeyCode = 51   // Backspace
    }
}
