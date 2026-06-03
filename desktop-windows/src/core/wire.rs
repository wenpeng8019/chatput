//! 桌面端 ⇄ 手机端、客户端 ⇄ 信令服务器之间的线缆协议常量。
//!
//! 这些字符串是跨进程、跨平台（macOS / Windows / Android）约定的协议字段，必须保持一致。
//! 集中在此，避免散落各处手写字面量。修改任何取值都需同步更新其他端对应常量。

/// 公共字段名。
pub mod key {
    pub const TYPE: &str = "type";
    pub const DATA: &str = "data";
    pub const TRANSPORT: &str = "transport";
}

/// WebRTC DataChannel 上的业务消息（桌面 ⇄ 手机）。
pub mod msg {
    /// DataChannel 的标签名（HOST 创建时指定）。
    pub const CHANNEL_LABEL: &str = "input";

    /// 桌面 → 手机：推送当前聚焦的输入会话。
    pub const SESSION: &str = "session";
    /// 桌面 → 手机：已上报过的输入窗口关闭，移除对应会话。
    pub const SESSION_CLOSED: &str = "session-closed";
    /// 手机 → 桌面：识别得到的文本。
    pub const TEXT: &str = "text";
    /// 手机 → 桌面：操作指令（回车/退格/全选/清空）。
    pub const ACTION: &str = "action";
    /// 手机 → 桌面：上报设备名。
    pub const HELLO: &str = "hello";
}

/// 信令服务器协议（客户端 ⇄ 信令服务器）。
pub mod signal {
    pub const CREATE_ROOM: &str = "create-room";
    pub const ROOM_CREATED: &str = "room-created";
    pub const JOIN_ROOM: &str = "join-room";
    pub const PEER_JOINED: &str = "peer-joined";
    pub const PEER_LEFT: &str = "peer-left";
    pub const SIGNAL: &str = "signal";
    pub const MESSAGE: &str = "message";
    pub const ERROR: &str = "error";
}

/// 端到端业务传输模式。
pub mod transport {
    pub const WEBRTC: &str = "webrtc";
    pub const WEBSOCKET: &str = "websocket";
}

/// 房间内角色。
pub mod role {
    pub const HOST: &str = "host";
    pub const GUEST: &str = "guest";
}

/// 信令错误原因。
pub mod reason {
    pub const INVALID_JSON: &str = "invalid-json";
    pub const ROOM_NOT_FOUND: &str = "room-not-found";
    pub const BAD_TOKEN: &str = "bad-token";
    pub const ROOM_FULL: &str = "room-full";
    pub const NOT_IN_ROOM: &str = "not-in-room";
    pub const UNKNOWN_TYPE: &str = "unknown-type";
}
