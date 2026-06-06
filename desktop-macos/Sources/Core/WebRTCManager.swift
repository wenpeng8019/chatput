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
    /// 手机请求开始采集某会话窗口（sessionId, 期望视口宽, 高）。
    var onScreenStart: ((String, Int, Int) -> Void)?
    /// 手机请求停止采集某会话窗口（sessionId）。
    var onScreenStop: ((String) -> Void)?
    /// 手机拖动视口（sessionId, x, y, w, h，窗口像素系）。
    var onViewport: ((String, Int, Int, Int, Int) -> Void)?
    /// 手机 → 桌面：触控转鼠标（sessionId, x, y，窗口逻辑坐标）。
    var onPointerDown: ((String, Int, Int) -> Void)?
    var onPointerUp: ((String, Int, Int) -> Void)?
    /// 手机 → 桌面：触控转滚轮（sessionId, dx, dy）。
    var onPointerScroll: ((String, Int, Int) -> Void)?
    var onLog: ((String) -> Void)?

    private static let encoderFactory = FilteredEncoderFactory()
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let decoder = RTCDefaultVideoDecoderFactory()
        let encoderCodecs = RTCDefaultVideoEncoderFactory.supportedCodecs().map { "\($0.name)" }
        let decoderCodecs = decoder.supportedCodecs().map { "\($0.name)" }
        NSLog("[chatput] WebRTC available encoders: \(encoderCodecs.joined(separator: ", "))")
        NSLog("[chatput] WebRTC available decoders: \(decoderCodecs.joined(separator: ", "))")
        return RTCPeerConnectionFactory(encoderFactory: encoderFactory, decoderFactory: decoder)
    }()

    private var pc: RTCPeerConnection?
    private var channel: RTCDataChannel?

    // 远程窗口画面（2.0）：预协商一条 sendonly 视频轨，开启采集时才喂帧。
    private var videoSource: RTCVideoSource?
    private var videoTrack: RTCVideoTrack?
    private var videoCapturer: RTCVideoCapturer?
    private var lastAdaptW: Int32 = 0
    private var lastAdaptH: Int32 = 0

    private let iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"])]

    // MARK: - 建连

    func createConnectionAndOffer() {
        // 每次建连前更新编码器偏好（设置变更后重连即可切换）。
        Self.encoderFactory.prefCodec = AppSettings.shared.screenCodec

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

        // 预协商一条 sendonly 视频轨：开启远程画面前轨道静默，避免中途重协商。
        let source = WebRTCManager.factory.videoSource()
        let track = WebRTCManager.factory.videoTrack(with: source, trackId: "screen0")
        self.videoSource = source
        self.videoTrack = track
        self.videoCapturer = RTCVideoCapturer(delegate: source)
        let txInit = RTCRtpTransceiverInit()
        txInit.direction = .sendOnly
        txInit.streamIds = ["screen"]
        let _ = pc.addTransceiver(with: track, init: txInit)
        // 提前设好码率，避免首帧 ramp-up 导致模糊。
        DispatchQueue.main.async { [weak self] in self?.raiseVideoBitrate() }

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
            "device": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "ts": session.ts,
        ]
        sendMessage(obj)
    }

    /// 通知手机移除一个已经关闭的桌面窗口会话。
    func sendSessionClosed(sessionId: String) {
        sendMessage([
            "type": Wire.Msg.sessionClosed,
            "sessionId": sessionId,
        ])
    }

    func sendMessage(_ obj: [String: Any]) {
        guard let channel = channel, channel.readyState == .open,
              let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: false))
    }

    /// 经 DataChannel 发送二进制帧（用于小地图缩略图）。
    func sendBinary(_ data: Data) {
        guard let channel = channel, channel.readyState == .open else { return }
        channel.sendData(RTCDataBuffer(data: data, isBinary: true))
    }

    /// 把一帧采集到的窗口子区域画面喂入预协商的视频轨。
    func pushVideoFrame(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64) {
        guard let source = videoSource, let capturer = videoCapturer else {
            onLog?("pushVideoFrame: source or capturer nil"); return
        }
        let w = Int32(CVPixelBufferGetWidth(pixelBuffer))
        let h = Int32(CVPixelBufferGetHeight(pixelBuffer))
        // 锁定输出格式为采集分辨率，禁止 WebRTC 自适应降采样（否则画面发虚）。
        if w != lastAdaptW || h != lastAdaptH {
            lastAdaptW = w; lastAdaptH = h
            let fps = Int32(AppSettings.shared.screenFPS.value)
            source.adaptOutputFormat(toWidth: w, height: h, fps: fps)
            raiseVideoBitrate()
            // 分辨率变化后重协商 WebRTC 会话，让对端解码器更新尺寸
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.renegotiate()
            }
        }
        let rtcBuffer = RTCCVPixelBuffer(pixelBuffer: pixelBuffer)
        let frame = RTCVideoFrame(buffer: rtcBuffer, rotation: ._0, timeStampNs: timeStampNs)
        source.capturer(capturer, didCapture: frame)
    }

    /// 抬高视频发送码率上限，避免文字画面被压糊；按设置控制画质降级。
    private func raiseVideoBitrate() {
        guard let pc = pc else { return }
        guard let sender = pc.senders.first(where: { $0.track?.kind == "video" }) else { return }
        let params = sender.parameters
        for encoding in params.encodings {
            encoding.maxBitrateBps = NSNumber(value: 8_000_000)
            encoding.minBitrateBps = NSNumber(value: 4_000_000)
            encoding.maxFramerate = NSNumber(value: AppSettings.shared.screenFPS.value)
        }
        let quality = AppSettings.shared.screenQuality
        params.degradationPreference = NSNumber(value:
            quality == .disabled ? 0 : (quality == .balanced ? 1 : 2))
        sender.parameters = params
    }

    /// 分辨率变化后重协商 SDP，让对端解码器更新尺寸。
    private func renegotiate() {
        guard let pc = pc else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, error in
            guard let self = self, let sdp = sdp else { return }
            pc.setLocalDescription(sdp) { _ in
                self.onLocalSignal?(["sdp": ["type": RTCSessionDescription.string(for: sdp.type), "sdp": sdp.sdp]])
            }
        }
    }

    /// 关闭当前连接与通道（重连/切换配置时调用）。
    func close() {
        channel?.close()
        channel = nil
        videoTrack = nil
        videoSource = nil
        videoCapturer = nil
        lastAdaptW = 0
        lastAdaptH = 0
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
        case Wire.Msg.screenStart:
            let sessionId = obj["sessionId"] as? String ?? ""
            let vp = obj["viewport"] as? [String: Any]
            let w = (vp?["w"] as? NSNumber)?.intValue ?? 0
            let h = (vp?["h"] as? NSNumber)?.intValue ?? 0
            onScreenStart?(sessionId, w, h)
        case Wire.Msg.screenStop:
            onScreenStop?(obj["sessionId"] as? String ?? "")
        case Wire.Msg.viewport:
            let sessionId = obj["sessionId"] as? String ?? ""
            let x = (obj["x"] as? NSNumber)?.intValue ?? 0
            let y = (obj["y"] as? NSNumber)?.intValue ?? 0
            let w = (obj["w"] as? NSNumber)?.intValue ?? 0
            let h = (obj["h"] as? NSNumber)?.intValue ?? 0
            onViewport?(sessionId, x, y, w, h)
        case Wire.Msg.pointerDown:
            onPointerDown?(obj["sessionId"] as? String ?? "",
                           (obj["x"] as? NSNumber)?.intValue ?? 0,
                           (obj["y"] as? NSNumber)?.intValue ?? 0)
        case Wire.Msg.pointerUp:
            onPointerUp?(obj["sessionId"] as? String ?? "",
                         (obj["x"] as? NSNumber)?.intValue ?? 0,
                         (obj["y"] as? NSNumber)?.intValue ?? 0)
        case Wire.Msg.pointerScroll:
            onPointerScroll?(obj["sessionId"] as? String ?? "",
                             (obj["dx"] as? NSNumber)?.intValue ?? 0,
                             (obj["dy"] as? NSNumber)?.intValue ?? 0)
        default:
            break
        }
    }
}

/// 包装 RTCDefaultVideoEncoderFactory，按用户偏好只暴露指定编码器。
/// supportedCodecs() 只返回首选编码器，SDP offer 中将仅包含该 codec。
final class FilteredEncoderFactory: NSObject, RTCVideoEncoderFactory {
    var prefCodec: ScreenCodec = AppSettings.shared.screenCodec
    private let inner = RTCDefaultVideoEncoderFactory()

    private var prefName: String {
        switch prefCodec {
        case .h264: return "H264"
        case .vp8:  return "VP8"
        case .vp9:  return "VP9"
        }
    }

    func supportedCodecs() -> [RTCVideoCodecInfo] {
        let all = inner.supportedCodecs()
        // 偏好编码器排到首位；禁止动态码率时注入 startBitrate 跳过 BWE 爬升。
        if let preferred = all.first(where: { $0.name == prefName }) {
            var modified = preferred
            if AppSettings.shared.disableDynamicBitrate {
                var params = preferred.parameters
                params["startBitrate"] = "4000" // kbps
                modified = RTCVideoCodecInfo(name: preferred.name, parameters: params)
            }
            var reordered = all.filter { $0.name != prefName }
            reordered.insert(modified, at: 0)
            return reordered
        }
        return all
    }

    func createEncoder(_ info: RTCVideoCodecInfo) -> RTCVideoEncoder? {
        inner.createEncoder(info)
    }
}
