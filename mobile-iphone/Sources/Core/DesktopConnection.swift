import Foundation
import UIKit
import WebRTC

protocol ScreenListener: AnyObject {
    func onVideoTrack(_ track: RTCVideoTrack)
    func onThumbnail(sessionId: String, jpeg: Data)
    func onMeta(sessionId: String, winW: Int, winH: Int, scale: Float, x: Int, y: Int, w: Int, h: Int)
    func onScreenError(sessionId: String, message: String)
}

final class DesktopConnection: NSObject {
    let connectionId: String
    let payload: QRPairingPayload

    var status = "未连接"
    var isConnected = false
    var isConnecting = false
    var sessions: [DesktopSession] = []

    var connectionLabel: String { deviceLabel.isEmpty ? "房间 \(payload.roomId)" : deviceLabel }
    var transportLabel: String { payload.transportMode == .webSocket ? "WS 连接" : "P2P 连接" }

    var onStatusChanged: ((String, String, Bool) -> Void)?
    var onSessionsChanged: ((String) -> Void)?
    var onMessage: ((String, String, ChatMessage) -> Void)?
    var onConnected: ((String, QRPairingPayload) -> Void)?
    var onLabelChanged: ((String, String) -> Void)?
    var onPairingExpired: ((String, String) -> Bool)?

    weak var screenListener: ScreenListener? {
        didSet {
            if let track = remoteVideoTrack { screenListener?.onVideoTrack(track) }
        }
    }
    private var remoteVideoTrack: RTCVideoTrack?
    private var thumbChannel: RTCDataChannel?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    private var signaling: SignalingClient?
    private var peerConnection: RTCPeerConnection?
    private var dataChannel: RTCDataChannel?
    private var manualDisconnect = false
    private var isTearingDown = false
    private var deviceLabel = ""
    private let iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]

    init(payload: QRPairingPayload) {
        self.payload = payload
        self.connectionId = payload.connectionId
        super.init()
    }

    func connect() {
        manualDisconnect = false
        releaseTransports()
        isConnecting = true
        isConnected = false
        updateStatus("连接信令服务器…", connected: false)
        guard let url = URL(string: payload.url) else {
            handleError("二维码地址无效")
            return
        }
        signaling = SignalingClient(url: url, delegate: self)
        signaling?.connect(roomId: payload.roomId, token: payload.token)
    }

    func sessionById(_ sessionId: String) -> DesktopSession? {
        sessions.first { $0.sessionId == sessionId }
    }

    func sendText(session: DesktopSession, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isConnected else { return }
        sendPeerMessage([Wire.Key.type: Wire.Msg.text, "text": text, "sessionId": session.sessionId])
        let message = ChatMessage(text: text, fromMe: true)
        if let index = sessions.firstIndex(where: { $0.sessionId == session.sessionId }) {
            sessions[index].messages.append(message)
        }
        onMessage?(connectionId, session.sessionId, message)
    }

    func resendText(session: DesktopSession, text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, isConnected else { return }
        sendPeerMessage([Wire.Key.type: Wire.Msg.text, "text": text, "sessionId": session.sessionId])
    }

    func sendAction(session: DesktopSession, action: String) {
        guard isConnected else { return }
        sendPeerMessage([Wire.Key.type: Wire.Msg.action, "action": action, "sessionId": session.sessionId])
    }

    func startScreen(session: DesktopSession, viewportW: Int, viewportH: Int) {
        guard isConnected else { return }
        sendPeerMessage([
            Wire.Key.type: Wire.Msg.screenStart,
            "sessionId": session.sessionId,
            "viewport": ["w": viewportW, "h": viewportH]
        ])
    }

    func stopScreen(session: DesktopSession) {
        guard isConnected else { return }
        sendPeerMessage([Wire.Key.type: Wire.Msg.screenStop, "sessionId": session.sessionId])
    }

    func sendViewport(session: DesktopSession, x: Int, y: Int, w: Int, h: Int) {
        guard isConnected else { return }
        sendPeerMessage([
            Wire.Key.type: Wire.Msg.viewport,
            "sessionId": session.sessionId,
            "x": x, "y": y, "w": w, "h": h
        ])
    }

    func sendPointerDown(session: DesktopSession, x: Int, y: Int) {
        guard isConnected else { return }
        sendPeerMessage([Wire.Key.type: Wire.Msg.pointerDown, "sessionId": session.sessionId, "x": x, "y": y])
    }

    func sendPointerUp(session: DesktopSession, x: Int, y: Int) {
        guard isConnected else { return }
        sendPeerMessage([Wire.Key.type: Wire.Msg.pointerUp, "sessionId": session.sessionId, "x": x, "y": y])
    }

    func sendPointerScroll(session: DesktopSession, dx: Int, dy: Int) {
        guard isConnected else { return }
        sendPeerMessage([Wire.Key.type: Wire.Msg.pointerScroll, "sessionId": session.sessionId, "dx": dx, "dy": dy])
    }

    func disconnect() {
        manualDisconnect = true
        releaseTransports()
        isConnecting = false
        isConnected = false
        clearSessions()
        updateStatus("未连接", connected: false)
    }

    private func createPeerConnection() {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self)
    }

    private func handleRemoteSignal(_ data: [String: Any]) {
        if let sdp = data["sdp"] as? [String: Any],
           let typeRaw = sdp["type"] as? String,
           let sdpText = sdp["sdp"] as? String {
            let desc = RTCSessionDescription(type: RTCSessionDescription.type(for: typeRaw), sdp: sdpText)
            peerConnection?.setRemoteDescription(desc) { [weak self] error in
                if let error {
                    self?.handleError(error.localizedDescription)
                } else {
                    self?.createAnswer()
                }
            }
        } else if let candidate = data["candidate"] as? [String: Any],
                  let sdpText = candidate["candidate"] as? String {
            let ice = RTCIceCandidate(
                sdp: sdpText,
                sdpMLineIndex: Int32(candidate["sdpMLineIndex"] as? Int ?? 0),
                sdpMid: candidate["sdpMid"] as? String
            )
            peerConnection?.add(ice) { [weak self] error in
                if let error { self?.handleError(error.localizedDescription) }
            }
        }
    }

    private func createAnswer() {
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        peerConnection?.answer(for: constraints) { [weak self] sdp, error in
            guard let self, let sdp else {
                self?.handleError(error?.localizedDescription ?? "创建 answer 失败")
                return
            }
            self.peerConnection?.setLocalDescription(sdp) { [weak self] error in
                if let error {
                    self?.handleError(error.localizedDescription)
                    return
                }
                self?.signaling?.sendSignal([
                    "sdp": ["type": RTCSessionDescription.string(for: sdp.type), "sdp": sdp.sdp]
                ])
            }
        }
    }

    private func markConnected(_ text: String) {
        let firstConnect = !isConnected
        isConnecting = false
        isConnected = true
        if firstConnect { onConnected?(connectionId, payload) }
        updateStatus(text, connected: true)
    }

    private func updateStatus(_ text: String, connected: Bool) {
        status = text
        isConnected = connected
        onStatusChanged?(connectionId, text, connected)
    }

    private func handleError(_ reason: String) {
        releaseTransports()
        isConnecting = false
        clearSessions()
        if onPairingExpired?(connectionId, reason) == true {
            updateStatus("历史连接已失效，请重新扫码", connected: false)
        } else {
            updateStatus("错误: \(reason)", connected: false)
        }
    }

    private func handleRemoteDisconnected(_ text: String) {
        guard !manualDisconnect, !isTearingDown else { return }
        releaseTransports()
        isConnecting = false
        isConnected = false
        clearSessions()
        updateStatus(text, connected: false)
    }

    private func sendHello() {
        sendPeerMessage([Wire.Key.type: Wire.Msg.hello, "device": UIDevice.current.name])
    }

    private func sendPeerMessage(_ object: [String: Any]) {
        if payload.transportMode == .webSocket {
            signaling?.sendMessage(object)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return
        }
        guard let channel = dataChannel else {
            return
        }
        guard channel.readyState == .open else {
            return
        }
        let sent = channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    private func handlePeerMessage(_ object: [String: Any]) {
        let type = object[Wire.Key.type] as? String ?? "?"
        switch type {
        case Wire.Msg.session:
            upsertSession(object)
        case Wire.Msg.sessionClosed:
            if let sessionId = object["sessionId"] as? String { removeSession(sessionId) }
        case Wire.Msg.sessionInputLost:
            if let sessionId = object["sessionId"] as? String {
                if let idx = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
                    sessions[idx].inputAvailable = false
                    onSessionsChanged?(connectionId)
                }
            }
        case Wire.Msg.screenError:
            screenListener?.onScreenError(
                sessionId: object["sessionId"] as? String ?? "",
                message: object["message"] as? String ?? "采集失败")
        case Wire.Msg.screenMeta:
            handleScreenMeta(object)
        default:
            break
        }
    }

    private func handleScreenMeta(_ object: [String: Any]) {
        guard let listener = screenListener,
              let sessionId = object["sessionId"] as? String,
              let win = object["win"] as? [String: Any],
              let applied = object["applied"] as? [String: Any] else { return }
        listener.onMeta(
            sessionId: sessionId,
            winW: win["w"] as? Int ?? 0,
            winH: win["h"] as? Int ?? 0,
            scale: Float(win["scale"] as? Double ?? 2.0),
            x: applied["x"] as? Int ?? 0,
            y: applied["y"] as? Int ?? 0,
            w: applied["w"] as? Int ?? 0,
            h: applied["h"] as? Int ?? 0
        )
    }

    private func handleBinaryFrame(_ data: Data) {
        guard let listener = screenListener, data.count >= 2 else { return }
        let idLen = (Int(data[0]) << 8) | Int(data[1])
        guard idLen >= 0, 2 + idLen <= data.count else { return }
        let sessionId = String(data: data[2..<(2 + idLen)], encoding: .utf8) ?? ""
        let jpeg = data.subdata(in: (2 + idLen)..<data.count)
        listener.onThumbnail(sessionId: sessionId, jpeg: jpeg)
    }

    private func upsertSession(_ object: [String: Any]) {
        guard let sessionId = object["sessionId"] as? String else { return }
        let app = object["app"] as? String ?? ""
        let title = object["title"] as? String ?? ""
        let device = object["device"] as? String ?? ""
        if !device.isEmpty {
            deviceLabel = device
            onLabelChanged?(connectionId, device)
        }
        for index in sessions.indices { sessions[index].isActive = false }
        if let index = sessions.firstIndex(where: { $0.sessionId == sessionId }) {
            sessions[index].app = object["app"] as? String ?? sessions[index].app
            sessions[index].title = object["title"] as? String ?? sessions[index].title
            if !device.isEmpty { sessions[index].device = device }
            sessions[index].isActive = true
            sessions[index].inputAvailable = true
            let updated = sessions.remove(at: index)
            sessions.insert(updated, at: 0)
        } else {
            sessions.insert(
                DesktopSession(
                    connectionId: connectionId,
                    sessionId: sessionId,
                    app: object["app"] as? String ?? "",
                    title: object["title"] as? String ?? "",
                    device: device,
                    isActive: true
                ),
                at: 0
            )
        }
        onSessionsChanged?(connectionId)
    }

    private func removeSession(_ sessionId: String) {
        let oldCount = sessions.count
        sessions.removeAll { $0.sessionId == sessionId }
        if oldCount != sessions.count {
            if !sessions.contains(where: { $0.isActive }) { sessions.indices.first.map { sessions[$0].isActive = true } }
            onSessionsChanged?(connectionId)
        }
    }

    private func clearSessions() {
        guard !sessions.isEmpty else { return }
        sessions.removeAll()
        onSessionsChanged?(connectionId)
    }

    private func releaseTransports() {
        guard !isTearingDown else { return }
        isTearingDown = true
        let dc = dataChannel
        let tc = thumbChannel
        let pc = peerConnection
        let sig = signaling
        dataChannel = nil
        thumbChannel = nil
        peerConnection = nil
        signaling = nil
        remoteVideoTrack = nil
        dc?.delegate = nil
        dc?.close()
        tc?.delegate = nil
        tc?.close()
        pc?.delegate = nil
        pc?.close()
        sig?.close()
        isTearingDown = false
    }
}

extension DesktopConnection: SignalingClientDelegate {
    func signalingPeerJoined() {
        if payload.transportMode == .webSocket {
            markConnected("WebSocket 已连接")
            sendHello()
        } else {
            updateStatus("配对成功，正在建立连接…", connected: false)
            createPeerConnection()
        }
    }

    func signalingReceivedSignal(_ data: [String: Any]) {
        guard payload.transportMode == .webRTC else { return }
        handleRemoteSignal(data)
    }

    func signalingReceivedMessage(_ data: [String: Any]) {
        handlePeerMessage(data)
    }

    func signalingPeerLeft() {
        handleRemoteDisconnected("桌面端已断开")
    }

    func signalingError(_ reason: String) {
        guard !manualDisconnect else { return }
        handleError(reason)
    }

    func signalingClosed() {
        guard !manualDisconnect else { return }
        handleRemoteDisconnected("桌面断开")
    }
}

extension DesktopConnection: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        signaling?.sendSignal([
            "candidate": [
                "candidate": candidate.sdp,
                "sdpMid": candidate.sdpMid ?? "",
                "sdpMLineIndex": Int(candidate.sdpMLineIndex)
            ]
        ])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .connected || newState == .completed { markConnected("P2P 已连接") }
        if newState == .disconnected || newState == .failed || newState == .closed { handleRemoteDisconnected("桌面断开") }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        if dataChannel.label == Wire.Msg.channelLabel {
            self.dataChannel = dataChannel
        } else if dataChannel.label == Wire.Msg.thumbChannel {
            thumbChannel = dataChannel
        }
        dataChannel.delegate = self
    }

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        if let track = stream.videoTracks.first {
            remoteVideoTrack = track
            screenListener?.onVideoTrack(track)
        }
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

extension DesktopConnection: RTCDataChannelDelegate {
    @objc(dataChannelDidChangeState:)
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        guard dataChannel.label == Wire.Msg.channelLabel else { return }
        if dataChannel.readyState == .open {
            if self.dataChannel == nil {
                self.dataChannel = dataChannel
                dataChannel.delegate = self
            }
            markConnected("P2P 已连接")
            sendHello()
        }
        if dataChannel.readyState == .closing || dataChannel.readyState == .closed {
            handleRemoteDisconnected("桌面断开")
        }
    }

    @objc(dataChannel:didReceiveMessageWithBuffer:)
    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        if buffer.isBinary {
            if dataChannel.label == Wire.Msg.thumbChannel {
                handleBinaryFrame(buffer.data)
            }
            return
        }
        guard let object = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] else {
            return
        }
        DispatchQueue.main.async { [weak self] in self?.handlePeerMessage(object) }
    }
}
