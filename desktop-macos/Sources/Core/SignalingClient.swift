import Foundation

/// 信令 WebSocket 客户端（URLSessionWebSocketTask）。
/// 协议与 signaling-server 一致：JSON 文本帧。
final class SignalingClient: NSObject {
    var onOpen: (() -> Void)?
    var onMessage: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    private var task: URLSessionWebSocketTask?
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }()
    private var closedByUs = false

    func connect(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        closedByUs = false
        task?.cancel()
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop()
    }

    func send(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    func close() {
        closedByUs = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                if !self.closedByUs { self.onClose?() }
            case .success(let message):
                switch message {
                case .string(let text):
                    self.dispatch(text)
                case .data(let data):
                    if let text = String(data: data, encoding: .utf8) { self.dispatch(text) }
                @unknown default:
                    break
                }
                self.receiveLoop()
            }
        }
    }

    private func dispatch(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        onMessage?(obj)
    }
}

extension SignalingClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        if !closedByUs { onClose?() }
    }
}
