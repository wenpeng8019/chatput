import Foundation
import WebRTC

/// 桌面端 WebRTC HOST。
/// 创建 PeerConnection 与 "input" DataChannel，发 offer，收 answer/candidate，
/// 通过 DataChannel 收手机的 text、发 session。
final class WebRTCManager: NSObject {
    /// 需要经信令转发给对端的本地信令（{sdp:...} 或 {candidate:...}）。
    var onLocalSignal: (([String: Any]) -> Void)?
    var onConnected: (() -> Void)?
    /// DataChannel 真正 open（可发送）时触发，用于补发首个会话。
    var onChannelOpen: (() -> Void)?
    var onText: ((String) -> Void)?
    /// 收到手机的操作指令（回车/回退/全选/清空）。
    var onAction: ((String) -> Void)?
    /// 收到手机上报的设备名。
    var onDevice: ((String) -> Void)?
    var onLog: ((String) -> Void)?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
    }()

    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?

    private let iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]

    // MARK: - 建连

    func createConnectionAndOffer() {
        let config = RTCConfiguration()
        config.iceServers = iceServers
        config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        guard let pc = WebRTCManager.factory.peerConnection(with: config,
                                                            constraints: constraints,
                                                            delegate: self) else {
            onLog?("创建 PeerConnection 失败")
            return
        }
        self.pc = pc

        // HOST 创建 DataChannel。
        let dcConfig = RTCDataChannelConfiguration()
        if let dc = pc.dataChannel(forLabel: Wire.Msg.channelLabel, configuration: dcConfig) {
            dc.delegate = self
            self.channel = dc
        }

        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self, let sdp = sdp else {
                self?.onLog?("createOffer 失败: \(error?.localizedDescription ?? "")")
                return
            }
            pc.setLocalDescription(sdp) { _ in
                let sdpDict: [String: Any] = [
                    "type": RTCSessionDescription.string(for: sdp.type),
                    "sdp": sdp.sdp,
                ]
                self.onLocalSignal?(["sdp": sdpDict])
            }
        }
    }

    // MARK: - 远端信令

    func handleRemoteSignal(_ data: [String: Any]) {
        if let sdp = data["sdp"] as? [String: Any],
           let typeStr = sdp["type"] as? String,
           let sdpStr = sdp["sdp"] as? String {
            let type = RTCSessionDescription.type(for: typeStr)
            let desc = RTCSessionDescription(type: type, sdp: sdpStr)
            pc?.setRemoteDescription(desc) { [weak self] err in
                if let err = err { self?.onLog?("setRemote 失败: \(err.localizedDescription)") }
            }
        } else if let cand = data["candidate"] as? [String: Any],
                  let sdpStr = cand["candidate"] as? String {
            let candidate = RTCIceCandidate(
                sdp: sdpStr,
                sdpMLineIndex: Int32(cand["sdpMLineIndex"] as? Int ?? 0),
                sdpMid: cand["sdpMid"] as? String
            )
            pc?.add(candidate) { [weak self] err in
                if let err = err { self?.onLog?("addCandidate 失败: \(err.localizedDescription)") }
            }
        }
    }

    // MARK: - 发送

    /// 把焦点会话推送给手机，让其新建/切换会话。
    func sendSession(_ session: FocusSession) {
        let obj: [String: Any] = [
            "type": Wire.Msg.session,
            "sessionId": session.id,
            "app": session.app,
            "title": session.title,
            "ts": session.ts,
        ]
        sendMessage(obj)
    }

    func sendMessage(_ obj: [String: Any]) {
        guard let channel = channel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    /// 关闭当前连接与通道（重连/切换配置时调用）。
    func close() {
        channel?.close()
        channel = nil
        pc?.close()
        pc = nil
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCManager: RTCPeerConnectionDelegate {
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let cand: [String: Any] = [
            "candidate": candidate.sdp,
            "sdpMid": candidate.sdpMid ?? "",
            "sdpMLineIndex": Int(candidate.sdpMLineIndex),
        ]
        onLocalSignal?(["candidate": cand])
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        onLog?("ice state: \(newState.rawValue)")
        if newState == .connected || newState == .completed {
            onConnected?()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        // GUEST 不会创建通道；这里一般不触发，但保留以防万一。
        dataChannel.delegate = self
        self.channel = dataChannel
    }

    // 以下为协议要求但本场景不使用的回调。
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
}

// MARK: - RTCDataChannelDelegate

extension WebRTCManager: RTCDataChannelDelegate {
    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        onLog?("datachannel state: \(dataChannel.readyState.rawValue)")
        if dataChannel.readyState == .open {
            onConnected?()
            onChannelOpen?()
        }
    }

    func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard let obj = try? JSONSerialization.jsonObject(with: buffer.data) as? [String: Any] else { return }
        switch obj["type"] as? String {
        case Wire.Msg.text:
            if let text = obj["text"] as? String { onText?(text) }
        case Wire.Msg.action:
            if let action = obj["action"] as? String { onAction?(action) }
        case Wire.Msg.hello:
            if let device = obj["device"] as? String { onDevice?(device) }
        default:
            break
        }
    }
}
