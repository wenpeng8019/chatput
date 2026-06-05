import Foundation
import AppKit
import Combine
import Network

/// 顶层协调器：把信令、WebRTC、焦点监控、文字注入串起来。
/// 桌面端是 WebRTC HOST：创建房间 → 出二维码 → 等手机加入 → 发 offer → 建 DataChannel。
final class Coordinator {
    static let shared = Coordinator()

    private let state = AppState.shared
    private let settings = AppSettings.shared
    private lazy var signaling = SignalingClient()
    private lazy var webrtc = WebRTCManager()
    private lazy var server = SignalingServer()
    private let focus = FocusMonitor()
    private let injector = TextInjector()
    private let windowCapturer = WindowCapturer()
    private let pointerInjector = PointerInjector()

    private var roomId = ""
    private var token = ""
    private var reconnectWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var accessibilityTimer: Timer?
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "com.chatput.network-monitor")
    private var lastNetworkSignature = ""
    private var networkChangeWorkItem: DispatchWorkItem?
    private var shouldPromptRescanAfterRefresh = false

    // 远程窗口画面（2.0）：当前正在采集的会话与上次下发的生效视口（用于节流 meta）。
    private var screenSessionId = ""
    private var lastAppliedViewport = CGRect.zero

    private var transport: TransportMode { settings.transport }

    func start() {
        state.accessibilityGranted = TextInjector.isAccessibilityTrusted()
        wireServer()
        wireWebRTC()
        wireFocus()
        wireScreen()
        startAccessibilityPolling()
        startNetworkMonitoring()

        // 配置变更：仅当服务处于运行状态时才重启链路。
        settings.didApply
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.applyConfig() }
            .store(in: &cancellables)

        startService()
    }

    /// 周期性刷新辅助功能授权状态，授权后 tip 自动消失，无需重启。
    private func startAccessibilityPolling() {
        accessibilityTimer?.invalidate()
        let timer = Timer(timeInterval: AppConfig.Timing.accessibilityPoll, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let trusted = TextInjector.isAccessibilityTrusted()
            if trusted != self.state.accessibilityGranted {
                DispatchQueue.main.async { self.state.accessibilityGranted = trusted }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        accessibilityTimer = timer
    }

    // MARK: - 启停（用户显式控制）

    /// 启动服务：内置模式先起本地服务器，再连接信令；外部模式直接连。
    func startService() {
        started = true
        state.setServiceActive(true)
        bringUp()
    }

    /// 停止服务：彻底停止并保持停止，不自动重连，直到再次手动启动。
    func stopService() {
        started = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        stopScreenCapture(sessionId: "")
        signaling.close()
        webrtc.close()
        server.stop()
        roomId = ""
        token = ""
        DispatchQueue.main.async {
            self.state.setServiceActive(false)
            self.state.setServerState(running: false, port: 0)
            self.state.qrImage = nil
            self.state.roomCode = ""
            self.state.advertisedURL = ""
            self.state.connectedDevice = ""
            self.state.setStatus(zh: "已停止", en: "Stopped", connected: false)
        }
    }

    /// 配置变更：仅在运行时重启链路；已停止则保持停止（仅保存配置）。
    func applyConfig() {
        guard started else { return }
        restart()
    }

    /// 按当前配置启动链路（内部使用，不改变 started 意图）。
    private func bringUp() {
        guard started else { return }
        switch settings.mode {
        case .builtIn:
            state.setStatus(zh: "启动本地信令服务器…", en: "Starting local signaling server…", connected: false)
            server.start(port: UInt16(settings.listenPort))
            // 等服务器 ready 后再连（见 wireServer 的 onStateChange）。
        case .external:
            // 外部地址为空时无法运行，自动回退到内置模式（局域网）。
            guard !settings.externalURL.trimmingCharacters(in: .whitespaces).isEmpty else {
                settings.mode = .builtIn
                state.setStatus(zh: "外部地址为空，已切换到内置服务", en: "External address empty, switched to built-in", connected: false)
                server.start(port: UInt16(settings.listenPort))
                return
            }
            state.setServerState(running: false, port: 0)
            connectSignaling()
        }
    }

    /// 运行中重启：断开重连，必要时重启内置服务器。
    private func restart() {
        reconnectWorkItem?.cancel()
        networkChangeWorkItem?.cancel()
        stopScreenCapture(sessionId: "")
        signaling.close()
        webrtc.close()
        server.stop()
        roomId = ""
        token = ""
        // 清空面板上旧的房间/二维码/地址，避免新配置下仍显示陈旧信息。
        DispatchQueue.main.async {
            self.state.qrImage = nil
            self.state.roomCode = ""
            self.state.advertisedURL = ""
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConfig.Timing.restartDebounce) { [weak self] in
            self?.bringUp()
        }
    }

    // MARK: - 网络变化监听

    private func startNetworkMonitoring() {
        guard networkMonitor == nil else { return }
        let monitor = NWPathMonitor()
        networkMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handleNetworkPathUpdate(path)
        }
        monitor.start(queue: networkQueue)
    }

    private func handleNetworkPathUpdate(_ path: NWPath) {
        let ip = NetworkInfo.primaryLANIPv4() ?? ""
        let signature = [
            path.status == .satisfied ? "up" : "down",
            path.usesInterfaceType(.wifi) ? "wifi" : "",
            path.usesInterfaceType(.wiredEthernet) ? "wired" : "",
            path.usesInterfaceType(.cellular) ? "cellular" : "",
            ip,
        ].joined(separator: "|")

        guard !signature.isEmpty else { return }
        if lastNetworkSignature.isEmpty {
            lastNetworkSignature = signature
            return
        }
        guard signature != lastNetworkSignature else { return }

        let previous = lastNetworkSignature
        lastNetworkSignature = signature
        guard started else { return }

        if settings.mode == .builtIn || path.status == .satisfied {
            scheduleNetworkRefresh(from: previous, to: signature)
        }
    }

    private func scheduleNetworkRefresh(from oldValue: String, to newValue: String) {
        networkChangeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, self.started else { return }
            self.state.log("network changed:", oldValue, "->", newValue)
            self.shouldPromptRescanAfterRefresh = true
            self.state.setStatus(zh: "网络环境已变化，正在刷新连接…",
                                 en: "Network changed, refreshing connection…",
                                 connected: false)
            self.restart()
        }
        networkChangeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConfig.Timing.networkChangeDebounce, execute: work)
    }

    // MARK: - 内置信令服务器

    private func wireServer() {
        server.onLog = { [weak self] line in self?.state.log("[server]", line) }
        server.onError = { [weak self] message in
            self?.state.setStatus("⚠️ \(message)", connected: false)
        }
        server.onStateChange = { [weak self] running, port in
            guard let self = self else { return }
            self.state.setServerState(running: running, port: port)
            if running, self.started, self.settings.mode == .builtIn {
                // 服务器就绪，桌面端作为 host 连接自己的服务器。
                self.connectSignaling()
            }
        }
    }

    // MARK: - 信令

    private func connectSignaling() {
        let url = settings.hostConnectURL
        if settings.mode == .builtIn, settings.resolvedAdvertisedHost == nil {
            DispatchQueue.main.async {
                self.state.qrImage = nil
                self.state.roomCode = ""
                self.state.advertisedURL = ""
            }
            state.setStatus(zh: "等待可用网络地址…", en: "Waiting for a reachable network address…", connected: false)
            state.log("skip room creation: no reachable LAN address")
            return
        }
        guard !url.isEmpty else {
            state.setStatus(zh: "信令地址为空，请在设置中填写", en: "Signaling address empty, set it in Settings", connected: false)
            return
        }
        state.setStatus(zh: "连接信令服务器…", en: "Connecting to signaling server…", connected: false)

        signaling.onOpen = { [weak self] in
            self?.state.setStatus(zh: "已连接信令，创建房间…", en: "Connected, creating room…", connected: false)
            self?.signaling.send(["type": Wire.Signal.createRoom])
        }
        signaling.onMessage = { [weak self] msg in
            self?.handleSignalingMessage(msg)
        }
        signaling.onClose = { [weak self] in
            guard let self = self, self.started else { return }
            self.state.setStatus(zh: "信令断开，3 秒后重连…", en: "Signaling lost, reconnecting in 3s…", connected: false)
            let work = DispatchWorkItem { [weak self] in
                self?.signaling.connect(urlString: self?.settings.hostConnectURL ?? "")
            }
            self.reconnectWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + AppConfig.Timing.reconnectDelay, execute: work)
        }

        signaling.connect(urlString: url)
    }

    private func handleSignalingMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case Wire.Signal.roomCreated:
            roomId = msg["roomId"] as? String ?? ""
            token = msg["token"] as? String ?? ""
            let advertised = settings.advertisedURL
            let refreshed = shouldPromptRescanAfterRefresh
            shouldPromptRescanAfterRefresh = false
            let payload: [String: Any] = [
                "url": advertised,
                "roomId": roomId,
                "token": token,
                Wire.Key.transport: transport.rawValue,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self.state.roomCode = "房间 \(self.roomId)"
                self.state.advertisedURL = advertised
                self.state.qrImage = QRCodeGenerator.image(from: json, size: 240)
                if refreshed {
                    self.state.setStatus(zh: "二维码已刷新，请重新扫码", en: "QR code refreshed, please scan again", connected: false)
                } else {
                    self.state.setStatus(zh: "等待手机扫码配对…", en: "Waiting for phone to scan…", connected: false)
                }
            }
            state.log("room created:", roomId, "advertise:", advertised)

        case Wire.Signal.peerJoined:
            // 桌面端是 host：手机加入后由我方发起 offer。
            if (msg["role"] as? String) == Wire.Role.host {
                if transport == .webrtc {
                    state.log("guest joined, creating offer")
                    state.setStatus(zh: "配对成功，建立连接…", en: "Paired, establishing connection…", connected: false)
                    webrtc.createConnectionAndOffer()
                } else {
                    state.log("guest joined, websocket transport ready")
                    state.setStatus(zh: "WebSocket 已连接 ✅", en: "WebSocket connected ✅", connected: true)
                    focus.ensureCurrentDelivered()
                }
            }

        case Wire.Signal.signal:
            if let data = msg["data"] as? [String: Any] {
                webrtc.handleRemoteSignal(data)
            }

        case Wire.Signal.message:
            if let data = msg[Wire.Key.data] as? [String: Any] {
                handlePeerMessage(data)
            }

        case Wire.Signal.peerLeft:
            state.log("peer left")
            stopScreenCapture(sessionId: "")
            state.setConnectedDevice("")
            state.setStatus(zh: "手机已断开，等待重连…", en: "Phone disconnected, waiting to reconnect…", connected: false)

        case Wire.Signal.error:
            state.log("signaling error:", msg["reason"] ?? "")

        default:
            break
        }
    }

    // MARK: - WebRTC

    private func wireWebRTC() {
        webrtc.onLocalSignal = { [weak self] data in
            self?.signaling.send(["type": "signal", "data": data])
        }
        webrtc.onConnected = { [weak self] in
            self?.state.setStatus(zh: "P2P 已连接 ✅", en: "P2P connected ✅", connected: true)
        }
        // DataChannel 真正可发时补发当前焦点会话（首次连通瞬间通道可能尚未 open）。
        webrtc.onChannelOpen = { [weak self] in
            self?.focus.ensureCurrentDelivered()
        }
        webrtc.onText = { [weak self] text in
            self?.state.log("recv text:", text)
            self?.injector.inject(text)
        }
        webrtc.onAction = { [weak self] action in
            self?.state.log("recv action:", action)
            if let act = TextInjector.Action(rawValue: action) {
                self?.injector.perform(act)
            }
        }
        webrtc.onDevice = { [weak self] device in
            self?.state.log("device:", device)
            self?.state.setConnectedDevice(device)
        }
        webrtc.onLog = { [weak self] line in
            self?.state.log(line)
        }
    }

    // MARK: - 远程窗口画面（2.0）

    /// 把采集器的输出接到 WebRTC，并响应手机的开始/停止/视口控制。
    private func wireScreen() {
        windowCapturer.onLog = { [weak self] line in self?.state.log("[screen]", line) }
        pointerInjector.onLog = { [weak self] line in self?.state.log("[pointer]", line) }
        windowCapturer.onWindowReady = { [weak self] frame, scale in
            guard let self = self else { return }
            let contentLogicalH = self.windowCapturer.contentPixelSize.height / scale
            self.pointerInjector.updateWindow(frame: frame, scale: scale, contentLogicalH: contentLogicalH)
        }
        windowCapturer.onFrame = { [weak self] pixelBuffer, ts in
            self?.webrtc.pushVideoFrame(pixelBuffer, timeStampNs: ts)
        }
        windowCapturer.onThumbnail = { [weak self] jpeg in
            guard let self = self, !self.screenSessionId.isEmpty else { return }
            self.webrtc.sendBinary(self.screenThumbFrame(sessionId: self.screenSessionId, jpeg: jpeg))
        }
        windowCapturer.onMeta = { [weak self] winW, winH, applied in
            guard let self = self, !self.screenSessionId.isEmpty else { return }
            // 仅当生效视口变化时才下发 meta，避免每帧刷 JSON。
            guard applied != self.lastAppliedViewport else { return }
            self.lastAppliedViewport = applied
            self.webrtc.sendMessage([
                Wire.Key.type: Wire.Msg.screenMeta,
                "sessionId": self.screenSessionId,
                "win": ["w": winW, "h": winH, "scale": Double(self.windowCapturer.backingScale)],
                "applied": [
                    "x": Int(applied.origin.x), "y": Int(applied.origin.y),
                    "w": Int(applied.width), "h": Int(applied.height),
                ],
            ])
        }

        webrtc.onScreenStart = { [weak self] sessionId, w, h in
            self?.startScreenCapture(sessionId: sessionId, viewportW: w, viewportH: h)
        }
        webrtc.onScreenStop = { [weak self] sessionId in
            self?.stopScreenCapture(sessionId: sessionId)
        }
        webrtc.onViewport = { [weak self] sessionId, x, y, w, h in
            guard let self = self, sessionId == self.screenSessionId else { return }
            self.windowCapturer.setViewport(x: x, y: y, w: w, h: h)
        }
        webrtc.onPointerDown = { [weak self] sessionId, x, y in
            guard let self = self, sessionId == self.screenSessionId else { return }
            self.pointerInjector.mouseDown(x: x, y: y)
        }
        webrtc.onPointerUp = { [weak self] sessionId, x, y in
            guard let self = self, sessionId == self.screenSessionId else { return }
            self.pointerInjector.mouseUp(x: x, y: y)
        }
        webrtc.onPointerScroll = { [weak self] sessionId, dx, dy in
            guard let self = self, sessionId == self.screenSessionId else { return }
            self.pointerInjector.scroll(dx: dx, dy: dy)
        }
    }

    private func startScreenCapture(sessionId: String, viewportW: Int, viewportH: Int) {
        guard let session = state.sessions.first(where: { $0.id == sessionId }) else {
            state.log("[screen] 未找到会话:", sessionId)
            return
        }
        screenSessionId = sessionId
        lastAppliedViewport = .zero
        state.log("[screen] start:", session.app, "-", session.title)
        windowCapturer.start(sessionId: sessionId, app: session.app, title: session.title,
                             viewportW: viewportW, viewportH: viewportH)
    }

    private func stopScreenCapture(sessionId: String) {
        guard sessionId.isEmpty || sessionId == screenSessionId else { return }
        state.log("[screen] stop")
        windowCapturer.stop()
        screenSessionId = ""
        lastAppliedViewport = .zero
    }

    /// 缩略图二进制帧：`[2 字节大端 sessionId 长度][sessionId UTF-8][JPEG]`。
    private func screenThumbFrame(sessionId: String, jpeg: Data) -> Data {
        var data = Data()
        let idBytes = Array(sessionId.utf8)
        var len = UInt16(idBytes.count).bigEndian
        withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
        data.append(contentsOf: idBytes)
        data.append(jpeg)
        return data
    }

    // MARK: - 焦点监控

    private func wireFocus() {
        focus.onSession = { [weak self] session in
            guard let self = self else { return }
            self.state.upsertSession(session)
            self.state.log("focus:", session.app, "-", session.title)
            self.sendSession(session)
        }
        focus.onSessionClosed = { [weak self] sessionId in
            guard let self = self else { return }
            self.state.removeSession(id: sessionId)
            self.state.log("session closed:", sessionId)
            self.sendSessionClosed(sessionId: sessionId)
        }
    }

    private func sendSession(_ session: FocusSession) {
        let payload: [String: Any] = [
            Wire.Key.type: Wire.Msg.session,
            "sessionId": session.id,
            "app": session.app,
            "title": session.title,
            "device": Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
            "ts": session.ts,
        ]
        sendPeerMessage(payload)
    }

    private func sendSessionClosed(sessionId: String) {
        let payload: [String: Any] = [
            Wire.Key.type: Wire.Msg.sessionClosed,
            "sessionId": sessionId,
        ]
        sendPeerMessage(payload)
    }

    private func sendPeerMessage(_ payload: [String: Any]) {
        if transport == .webrtc {
            webrtc.sendMessage(payload)
        } else {
            signaling.send([Wire.Key.type: Wire.Signal.message, Wire.Key.data: payload])
        }
    }

    private func handlePeerMessage(_ payload: [String: Any]) {
        switch payload[Wire.Key.type] as? String {
        case Wire.Msg.text:
            if let text = payload["text"] as? String {
                state.log("recv text:", text)
                injector.inject(text)
            }
        case Wire.Msg.action:
            if let action = payload["action"] as? String {
                state.log("recv action:", action)
                if let act = TextInjector.Action(rawValue: action) {
                    injector.perform(act)
                }
            }
        case Wire.Msg.hello:
            if let device = payload["device"] as? String {
                state.log("device:", device)
                state.setConnectedDevice(device)
            }
        default:
            break
        }
    }
}
