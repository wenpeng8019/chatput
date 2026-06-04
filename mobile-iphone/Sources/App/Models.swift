import Foundation

struct QRPairingPayload: Codable, Hashable {
    let url: String
    let roomId: String
    let token: String
    let transport: String?

    var connectionId: String { "\(url)|\(roomId)" }
    var transportMode: TransportMode { TransportMode(rawValue: transport ?? Wire.Transport.webRTC) ?? .webRTC }
}

enum TransportMode: String, Codable {
    case webRTC = "webrtc"
    case webSocket = "websocket"
}

struct Pairing: Codable, Identifiable, Hashable {
    var id: String { payload.connectionId }
    let label: String
    let payload: QRPairingPayload
}

struct ConnectedDesktop: Identifiable, Hashable {
    let id: String
    let label: String
    let transportLabel: String
}

struct DesktopSession: Identifiable, Hashable {
    let connectionId: String
    let sessionId: String
    var app: String
    var title: String
    var device: String
    var messages: [ChatMessage] = []
    var isActive: Bool = false

    var id: String { "\(connectionId)#\(sessionId)" }
    var displayApp: String { app.isEmpty ? "未知应用" : app }
    var displayTitle: String { !device.isEmpty ? device : (title.isEmpty ? "当前窗口" : title) }
}

struct ChatMessage: Identifiable, Hashable {
    let id = UUID()
    let text: String
    let fromMe: Bool
    let ts: Date = Date()
}
