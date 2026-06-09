import Foundation

/// 桌面端 ⇄ 手机端、客户端 ⇄ 信令服务器之间的线缆协议常量。
///
/// 这些字符串是跨进程、跨平台（macOS / Android）约定的协议字段，必须保持一致。
/// 集中在此，避免散落在各文件里手写字面量导致拼写不一致、改了一处漏了另一处。
/// 注意：修改任何取值都需要同步更新 Android 端对应常量。
enum Wire {
    /// 公共字段名。
    enum Key {
        static let type = "type"
        static let data = "data"
        static let transport = "transport"
    }

    /// WebRTC DataChannel 上的业务消息（桌面 ⇄ 手机）。
    enum Msg {
        /// 主 DataChannel 标签名（HOST 创建时指定）：JSON 消息。
        static let channelLabel = "input"
        /// 缩略图 DataChannel 标签名：无序二进制帧。
        static let thumbChannel = "thumb"

        /// 桌面 → 手机：推送当前聚焦的输入会话。
        static let session = "session"
        /// 桌面 → 手机：已上报过的输入窗口关闭，移除对应会话。
        static let sessionClosed = "session-closed"
        /// 桌面 → 手机：远程屏幕采集失败（如未找到窗口）。
        static let screenError = "screen-error"
        /// 桌面 → 手机：窗口仍在但输入控件暂时不可用（如 AI 助手弹出菜单遮住了输入框）。
        static let sessionInputLost = "session-input-lost"
        /// 手机 → 桌面：识别得到的文本。
        static let text = "text"
        /// 手机 → 桌面：操作指令（回车/退格/全选/清空）。
        static let action = "action"
        /// 手机 → 桌面：上报设备名。
        static let hello = "hello"

        // MARK: 远程窗口画面（2.0）

        /// 手机 → 桌面：请求开始采集某会话窗口；附期望视口像素尺寸 `viewport:{w,h}`。
        static let screenStart = "screen-start"
        /// 手机 → 桌面：停止采集该会话窗口。
        static let screenStop = "screen-stop"
        /// 手机 → 桌面：拖动平移视口（窗口像素系），节流发送 `{x,y,w,h}`。
        static let viewport = "viewport"
        /// 桌面 → 手机：窗口尺寸与实际生效视口，用于红框/clamp 校正。
        static let screenMeta = "screen-meta"
        /// 桌面 → 手机：周期性小地图缩略图（二进制帧：header + JPEG）。
        static let screenThumb = "screen-thumb"

        // MARK: 触控转鼠标（2.0）

        /// 手机 → 桌面：鼠标按下（x,y 为窗口逻辑坐标）。
        static let pointerDown = "pointer-down"
        /// 手机 → 桌面：鼠标抬起。
        static let pointerUp = "pointer-up"
        /// 手机 → 桌面：滚轮（dx,dy 为滚动量）。
        static let pointerScroll = "pointer-scroll"
    }

    /// 信令服务器协议（客户端 ⇄ 信令服务器）。
    enum Signal {
        static let createRoom = "create-room"
        static let restoreRoom = "restore-room"
        static let roomCreated = "room-created"
        static let joinRoom = "join-room"
        static let peerJoined = "peer-joined"
        static let peerLeft = "peer-left"
        static let signal = "signal"
        static let message = "message"
        static let error = "error"
    }

    /// 端到端业务传输模式。
    enum Transport {
        static let webrtc = "webrtc"
        static let websocket = "websocket"
    }

    /// 房间内角色。
    enum Role {
        static let host = "host"
        static let guest = "guest"
    }

    /// 信令错误原因。
    enum Reason {
        static let invalidJSON = "invalid-json"
        static let roomNotFound = "room-not-found"
        static let badToken = "bad-token"
        static let roomFull = "room-full"
        static let notInRoom = "not-in-room"
        static let unknownType = "unknown-type"
    }
}
