import Foundation
import AppKit
import Combine

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

    private var roomId = ""
    private var token = ""
    private var reconnectWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var accessibilityTimer: Timer?

    func start() {
        state.accessibilityGranted = TextInjector.isAccessibilityTrusted()
        wireServer()
        wireWebRTC()
        wireFocus()
        startAccessibilityPolling()

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
            let payload: [String: Any] = [
                "url": advertised,
                "roomId": roomId,
                "token": token,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self.state.roomCode = "房间 \(self.roomId)"
                self.state.advertisedURL = advertised
                self.state.qrImage = QRCodeGenerator.image(from: json, size: 240)
                self.state.setStatus(zh: "等待手机扫码配对…", en: "Waiting for phone to scan…", connected: false)
            }
            state.log("room created:", roomId, "advertise:", advertised)

        case Wire.Signal.peerJoined:
            // 桌面端是 host：手机加入后由我方发起 offer。
            if (msg["role"] as? String) == Wire.Role.host {
                state.log("guest joined, creating offer")
                state.setStatus(zh: "配对成功，建立连接…", en: "Paired, establishing connection…", connected: false)
                webrtc.createConnectionAndOffer()
            }

        case Wire.Signal.signal:
            if let data = msg["data"] as? [String: Any] {
                webrtc.handleRemoteSignal(data)
            }

        case Wire.Signal.peerLeft:
            state.log("peer left")
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
            self?.focus.start()
        }
        // DataChannel 真正可发时补发当前焦点会话（首次连通瞬间通道可能尚未 open）。
        webrtc.onChannelOpen = { [weak self] in
            self?.focus.resendCurrent()
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

    // MARK: - 焦点监控

    private func wireFocus() {
        focus.onSession = { [weak self] session in
            guard let self = self else { return }
            self.state.upsertSession(session)
            self.state.log("focus:", session.app, "-", session.title)
            self.webrtc.sendSession(session)
        }
    }
}
