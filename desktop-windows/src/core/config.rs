//! 集中管理散落各处的"魔法数字"：时长、限制等。
//! 便于统一调优，避免同一含义的常量在多个文件里各写一份。

use std::time::Duration;

/// 各类时间间隔。
pub mod timing {
    use super::Duration;

    /// 已上报窗口是否仍存在的检测间隔。
    pub const WINDOW_EXISTENCE_POLL: Duration = Duration::from_millis(1000);
    /// 粘贴完成后还原剪贴板的延迟。
    pub const CLIPBOARD_RESTORE: Duration = Duration::from_millis(300);
    /// 网络变化检测轮询间隔。
    pub const NETWORK_MONITOR_POLL: Duration = Duration::from_millis(2000);
    /// 网络变化后重启链路的缓冲延迟。
    pub const NETWORK_CHANGE_DEBOUNCE: Duration = Duration::from_millis(1000);
    /// 信令断开后自动重连延迟。
    pub const RECONNECT_DELAY: Duration = Duration::from_secs(3);
    /// 配置变更后重启链路前的缓冲延迟。
    pub const RESTART_DEBOUNCE: Duration = Duration::from_millis(300);
    /// 缩略图发送间隔。
    pub const THUMB_INTERVAL: Duration = Duration::from_secs(1);
    /// 缩略图最大边长。
    pub const THUMB_MAX_EDGE: u32 = 240;
}

/// 各类容量上限。
pub mod limit {
    /// 调试日志保留的最大行数。
    pub const LOG_LINES: usize = 200;
    /// 会话列表保留的最大条目数。
    pub const SESSIONS: usize = 30;
}
