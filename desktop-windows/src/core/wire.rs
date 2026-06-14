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
    /// 主 DataChannel 标签名（HOST 创建时指定）：JSON 消息。
    pub const CHANNEL_LABEL: &str = "input";
    /// 缩略图 DataChannel 标签名：无序二进制帧。
    pub const THUMB_CHANNEL: &str = "thumb";

    /// 桌面 → 手机：推送当前聚焦的输入会话。
    pub const SESSION: &str = "session";
    /// 桌面 → 手机：已上报过的输入窗口关闭，移除对应会话。
    pub const SESSION_CLOSED: &str = "session-closed";
    /// 桌面 → 手机：远程屏幕采集失败（如未找到窗口）。
    pub const SCREEN_ERROR: &str = "screen-error";
    /// 桌面 → 手机：窗口仍在但输入控件暂时不可用。
    pub const SESSION_INPUT_LOST: &str = "session-input-lost";
    /// 手机 → 桌面：识别得到的文本。
    pub const TEXT: &str = "text";
    /// 手机 → 桌面：操作指令（回车/退格/全选/清空）。
    pub const ACTION: &str = "action";
    /// 手机 → 桌面：上报设备名。
    pub const HELLO: &str = "hello";

    // MARK: 远程窗口画面（2.0）

    /// 手机 → 桌面：请求开始采集某会话窗口；附期望视口像素尺寸 `viewport:{w,h}`。
    pub const SCREEN_START: &str = "screen-start";
    /// 手机 → 桌面：停止采集该会话窗口。
    pub const SCREEN_STOP: &str = "screen-stop";
    /// 手机 → 桌面：拖动平移视口（窗口像素系），节流发送 `{x,y,w,h}`。
    pub const VIEWPORT: &str = "viewport";
    /// 桌面 → 手机：窗口尺寸与实际生效视口，用于红框/clamp 校正。
    pub const SCREEN_META: &str = "screen-meta";
    /// 桌面 → 手机：周期性小地图缩略图（二进制帧：header + JPEG）。
    pub const SCREEN_THUMB: &str = "screen-thumb";

    // MARK: 触控转鼠标（2.0）

    /// 手机 → 桌面：鼠标按下（x,y 为窗口逻辑坐标）。
    pub const POINTER_DOWN: &str = "pointer-down";
    /// 手机 → 桌面：鼠标抬起。
    pub const POINTER_UP: &str = "pointer-up";
    /// 手机 → 桌面：滚轮（dx,dy 为滚动量）。
    pub const POINTER_SCROLL: &str = "pointer-scroll";
}

/// 信令服务器协议（客户端 ⇄ 信令服务器）。
pub mod signal {
    pub const CREATE_ROOM: &str = "create-room";
    pub const RESTORE_ROOM: &str = "restore-room";
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
