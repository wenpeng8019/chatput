import Foundation

enum Wire {
    enum Key {
        static let type = "type"
        static let data = "data"
        static let transport = "transport"
    }

    enum Msg {
        static let channelLabel = "input"
        static let thumbChannel = "thumb"
        static let session = "session"
        static let sessionClosed = "session-closed"
        static let sessionInputLost = "session-input-lost"
        static let text = "text"
        static let action = "action"
        static let hello = "hello"
        static let screenStart = "screen-start"
        static let screenStop = "screen-stop"
        static let screenMeta = "screen-meta"
        static let screenThumb = "screen-thumb"
        static let screenError = "screen-error"
        static let viewport = "viewport"
        static let pointerDown = "pointer-down"
        static let pointerUp = "pointer-up"
        static let pointerScroll = "pointer-scroll"
    }

    enum Signal {
        static let joinRoom = "join-room"
        static let peerJoined = "peer-joined"
        static let peerLeft = "peer-left"
        static let signal = "signal"
        static let message = "message"
        static let error = "error"
    }

    enum Transport {
        static let webRTC = "webrtc"
        static let webSocket = "websocket"
    }

    enum Reason {
        static let roomNotFound = "room-not-found"
        static let badToken = "bad-token"
    }
}
