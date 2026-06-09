import Foundation
import Network

/// 原生 WebSocket 信令服务器（Network.framework / NWProtocolWebSocket）。
/// 与 `signaling-server/src/index.js` 协议完全一致，零 Node 依赖，用于局域网内置模式。
///
/// 协议（JSON 文本帧）：
///   C->S {type:'create-room'}                  -> S->C {type:'room-created', roomId, token}
///   C->S {type:'join-room', roomId, token}     -> 双方: {type:'peer-joined', role}
///                                                 失败: {type:'error', reason}
///   C->S {type:'signal', data}                 -> 原样转发给房间内另一端
///   C->S {type:'message', data}                -> 业务消息中继给房间内另一端
///   S->C {type:'peer-left'}                     某端断开时通知另一端
final class SignalingServer {
    /// 房间内创建者是 host（桌面），加入者是 guest（手机）。
    private final class Room {
        let token: String
        weak var host: Client?
        weak var guest: Client?
        init(token: String) { self.token = token }
    }

    private final class Client {
        let connection: NWConnection
        var roomId: String?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    var onLog: ((String) -> Void)?
    /// 状态变化回调：running, port。主线程触发。
    var onStateChange: ((Bool, UInt16) -> Void)?
    /// 启动失败回调（如端口被占用）。主线程触发。
    var onError: ((String) -> Void)?

    private(set) var isRunning = false
    private(set) var port: UInt16 = 0

    private var listener: NWListener?
    private var rooms: [String: Room] = [:]
    private var clients: [ObjectIdentifier: Client] = [:]
    private let queue = DispatchQueue(label: "com.chatput.signaling-server")

    // MARK: - 生命周期

    /// 在指定端口启动。若已在运行会先停止。
    func start(port requestedPort: UInt16) {
        queue.async { [weak self] in
            self?.startLocked(port: requestedPort)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopLocked(notify: true)
        }
    }

    private func startLocked(port requestedPort: UInt16) {
        stopLocked(notify: false)

        guard let nwPort = NWEndpoint.Port(rawValue: requestedPort) else {
            emitState(running: false, port: 0)
            emitError("无效端口: \(requestedPort)")
            log("无效端口: \(requestedPort)")
            return
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let wsOptions = NWProtocolWebSocket.Options()
        wsOptions.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            let listener = try NWListener(using: params, on: nwPort)
            self.listener = listener
            self.port = requestedPort

            listener.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                self.queue.async {
                    switch state {
                    case .ready:
                        self.isRunning = true
                        self.emitState(running: true, port: requestedPort)
                        self.log("信令服务器已启动 ws://0.0.0.0:\(requestedPort)")
                    case .failed(let error):
                        self.log("信令服务器失败: \(error)")
                        self.emitError("端口 \(requestedPort) 监听失败（可能被占用）")
                        self.stopLocked(notify: true)
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.queue.async { self?.accept(connection) }
            }

            listener.start(queue: queue)
        } catch {
            log("无法监听端口 \(requestedPort): \(error)")
            emitError("无法监听端口 \(requestedPort)（可能被占用）")
            emitState(running: false, port: 0)
        }
    }

    private func stopLocked(notify: Bool) {
        for client in clients.values {
            client.connection.cancel()
        }
        clients.removeAll()
        rooms.removeAll()
        listener?.cancel()
        listener = nil
        let wasRunning = isRunning
        isRunning = false
        if notify && wasRunning {
            log("信令服务器已停止")
            emitState(running: false, port: port)
        }
        port = 0
    }

    // MARK: - 连接处理

    private func accept(_ connection: NWConnection) {
        let client = Client(connection)
        clients[ObjectIdentifier(connection)] = client

        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            self.queue.async {
                switch state {
                case .failed, .cancelled:
                    self.cleanup(client)
                default:
                    break
                }
            }
        }
        connection.start(queue: queue)
        receive(on: client)
    }

    private func receive(on client: Client) {
        client.connection.receiveMessage { [weak self] data, context, _, error in
            guard let self = self else { return }
            self.queue.async {
                if let error = error {
                    self.log("连接接收错误: \(error)")
                    self.cleanup(client)
                    return
                }

                if let context = context,
                   let meta = context.protocolMetadata.first as? NWProtocolWebSocket.Metadata {
                    switch meta.opcode {
                    case .close:
                        self.cleanup(client)
                        return
                    case .text, .binary:
                        if let data = data, !data.isEmpty {
                            self.handle(data, from: client)
                        }
                    default:
                        break
                    }
                }
                self.receive(on: client)
            }
        }
    }

    // MARK: - 协议

    private func handle(_ data: Data, from client: Client) {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else {
            sendJSON(["type": Wire.Signal.error, "reason": Wire.Reason.invalidJSON], to: client)
            return
        }

        switch type {
        case Wire.Signal.createRoom:
            let roomId = Self.genId(bytes: 3)   // 短，便于二维码
            let token = Self.genId(bytes: 8)
            let room = Room(token: token)
            room.host = client
            rooms[roomId] = room
            client.roomId = roomId
            sendJSON(["type": Wire.Signal.roomCreated, "roomId": roomId, "token": token], to: client)

        case Wire.Signal.restoreRoom:
            let roomId = obj["roomId"] as? String ?? Self.genId(bytes: 3)
            let token = obj["token"] as? String ?? Self.genId(bytes: 8)
            // If room with this ID already exists (stale), remove it first
            if let existing = rooms[roomId] {
                if let host = existing.host { host.roomId = nil; host.connection.cancel() }
                if let guest = existing.guest { guest.roomId = nil; guest.connection.cancel() }
                rooms.removeValue(forKey: roomId)
            }
            let room = Room(token: token)
            room.host = client
            rooms[roomId] = room
            client.roomId = roomId
            sendJSON(["type": Wire.Signal.roomCreated, "roomId": roomId, "token": token], to: client)

        case Wire.Signal.joinRoom:
            guard let roomId = obj["roomId"] as? String, let room = rooms[roomId] else {
                sendJSON(["type": Wire.Signal.error, "reason": Wire.Reason.roomNotFound], to: client)
                return
            }
            guard (obj["token"] as? String) == room.token else {
                sendJSON(["type": Wire.Signal.error, "reason": Wire.Reason.badToken], to: client)
                return
            }
            guard room.guest == nil else {
                sendJSON(["type": Wire.Signal.error, "reason": Wire.Reason.roomFull], to: client)
                return
            }
            room.guest = client
            client.roomId = roomId
            sendJSON(["type": Wire.Signal.peerJoined, "role": Wire.Role.guest], to: client)
            if let host = room.host {
                sendJSON(["type": Wire.Signal.peerJoined, "role": Wire.Role.host], to: host)
            }

        case Wire.Signal.signal:
            guard let roomId = client.roomId, let room = rooms[roomId] else {
                sendJSON(["type": Wire.Signal.error, "reason": Wire.Reason.notInRoom], to: client)
                return
            }
            if let peer = otherPeer(in: room, of: client), let data = obj["data"] {
                sendJSON(["type": Wire.Signal.signal, "data": data], to: peer)
            }

        case Wire.Signal.message:
            guard let roomId = client.roomId, let room = rooms[roomId] else {
                sendJSON(["type": Wire.Signal.error, "reason": Wire.Reason.notInRoom], to: client)
                return
            }
            if let peer = otherPeer(in: room, of: client), let data = obj[Wire.Key.data] {
                sendJSON([Wire.Key.type: Wire.Signal.message, Wire.Key.data: data], to: peer)
            }

        default:
            sendJSON(["type": Wire.Signal.error, "reason": Wire.Reason.unknownType], to: client)
        }
    }

    private func cleanup(_ client: Client) {
        clients.removeValue(forKey: ObjectIdentifier(client.connection))
        client.connection.cancel()

        guard let roomId = client.roomId, let room = rooms[roomId] else { return }
        let peer = otherPeer(in: room, of: client)
        if room.host === client { room.host = nil }
        if room.guest === client { room.guest = nil }
        if let peer = peer {
            sendJSON(["type": Wire.Signal.peerLeft], to: peer)
        }
        if room.host == nil && room.guest == nil {
            rooms.removeValue(forKey: roomId)
        }
    }

    private func otherPeer(in room: Room, of client: Client) -> Client? {
        if room.host === client { return room.guest }
        if room.guest === client { return room.host }
        return nil
    }

    // MARK: - 发送

    private func sendJSON(_ obj: [String: Any], to client: Client) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])
        client.connection.send(content: data,
                               contentContext: context,
                               isComplete: true,
                               completion: .contentProcessed { _ in })
    }

    // MARK: - 工具

    private static func genId(bytes: Int) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { ptr in
            SecRandomCopyBytes(kSecRandomDefault, bytes, ptr.baseAddress!)
        }
        return data.map { String(format: "%02x", $0) }.joined()
    }

    private func log(_ line: String) {
        DispatchQueue.main.async { self.onLog?(line) }
    }

    private func emitState(running: Bool, port: UInt16) {
        DispatchQueue.main.async { self.onStateChange?(running, port) }
    }

    private func emitError(_ message: String) {
        DispatchQueue.main.async { self.onError?(message) }
    }
}
