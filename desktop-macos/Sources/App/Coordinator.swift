import Foundation
import AppKit

/// 顶层协调器：把信令、WebRTC、焦点监控、文字注入串起来。
/// 桌面端是 WebRTC HOST：创建房间 → 出二维码 → 等手机加入 → 发 offer → 建 DataChannel。
final class Coordinator {
    // 信令服务器地址。手机与桌面都连它；该地址会写进二维码供手机扫码。
    static let signalingURL = "ws://10.2.101.210:8080"

    private let state = AppState.shared
    private lazy var signaling = SignalingClient()
    private lazy var webrtc = WebRTCManager()
    private let focus = FocusMonitor()
    private let injector = TextInjector()

    private var roomId = ""
    private var token = ""

    func start() {
        state.accessibilityGranted = TextInjector.isAccessibilityTrusted()
        wireWebRTC()
        wireFocus()
        connectSignaling()
    }

    // MARK: - 信令

    private func connectSignaling() {
        state.setStatus("连接信令服务器…", connected: false)

        signaling.onOpen = { [weak self] in
            self?.state.setStatus("已连接信令，创建房间…", connected: false)
            self?.signaling.send(["type": "create-room"])
        }
        signaling.onMessage = { [weak self] msg in
            self?.handleSignalingMessage(msg)
        }
        signaling.onClose = { [weak self] in
            self?.state.setStatus("信令断开，3 秒后重连…", connected: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                self?.signaling.connect(urlString: Coordinator.signalingURL)
            }
        }

        signaling.connect(urlString: Coordinator.signalingURL)
    }

    private func handleSignalingMessage(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "room-created":
            roomId = msg["roomId"] as? String ?? ""
            token = msg["token"] as? String ?? ""
            let payload: [String: Any] = [
                "url": Coordinator.signalingURL,
                "roomId": roomId,
                "token": token,
            ]
            let json = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            DispatchQueue.main.async {
                self.state.roomCode = "房间 \(self.roomId)"
                self.state.qrImage = QRCodeGenerator.image(from: json, size: 240)
                self.state.setStatus("等待手机扫码配对…", connected: false)
            }
            state.log("room created:", roomId)

        case "peer-joined":
            // 桌面端是 host：手机加入后由我方发起 offer。
            if (msg["role"] as? String) == "host" {
                state.log("guest joined, creating offer")
                state.setStatus("配对成功，建立连接…", connected: false)
                webrtc.createConnectionAndOffer()
            }

        case "signal":
            if let data = msg["data"] as? [String: Any] {
                webrtc.handleRemoteSignal(data)
            }

        case "peer-left":
            state.log("peer left")
            state.setStatus("手机已断开，等待重连…", connected: false)

        case "error":
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
            self?.state.setStatus("P2P 已连接 ✅", connected: true)
            self?.focus.start()
        }
        webrtc.onText = { [weak self] text in
            self?.state.log("recv text:", text)
            self?.injector.inject(text)
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
