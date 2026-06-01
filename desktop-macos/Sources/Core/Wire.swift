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
    }

    /// WebRTC DataChannel 上的业务消息（桌面 ⇄ 手机）。
    enum Msg {
        /// DataChannel 的标签名（HOST 创建时指定）。
        static let channelLabel = "input"

        /// 桌面 → 手机：推送当前聚焦的输入会话。
        static let session = "session"
        /// 手机 → 桌面：识别得到的文本。
        static let text = "text"
        /// 手机 → 桌面：操作指令（回车/退格/全选/清空）。
        static let action = "action"
        /// 手机 → 桌面：上报设备名。
        static let hello = "hello"
    }

    /// 信令服务器协议（客户端 ⇄ 信令服务器）。
    enum Signal {
        static let createRoom = "create-room"
        static let roomCreated = "room-created"
        static let joinRoom = "join-room"
        static let peerJoined = "peer-joined"
        static let peerLeft = "peer-left"
        static let signal = "signal"
        static let error = "error"
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
