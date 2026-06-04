import Foundation

protocol SignalingClientDelegate: AnyObject {
    func signalingPeerJoined()
    func signalingReceivedSignal(_ data: [String: Any])
    func signalingReceivedMessage(_ data: [String: Any])
    func signalingPeerLeft()
    func signalingError(_ reason: String)
    func signalingClosed()
}

final class SignalingClient {
    private let url: URL
    private weak var delegate: SignalingClientDelegate?
    private var task: URLSessionWebSocketTask?
    private var isClosed = false
    private lazy var session = URLSession(configuration: .default)

    init(url: URL, delegate: SignalingClientDelegate) {
        self.url = url
        self.delegate = delegate
    }

    func connect(roomId: String, token: String) {
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        send([Wire.Key.type: Wire.Signal.joinRoom, "roomId": roomId, "token": token])
        receiveNext()
    }

    func sendSignal(_ data: [String: Any]) {
        send([Wire.Key.type: Wire.Signal.signal, Wire.Key.data: data])
    }

    func sendMessage(_ data: [String: Any]) {
        send([Wire.Key.type: Wire.Signal.message, Wire.Key.data: data])
    }

    func close() {
        isClosed = true
        delegate = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
    }

    private func send(_ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error { self?.delegateOnMain { $0.signalingError(error.localizedDescription) } }
        }
    }

    private func receiveNext() {
        guard !isClosed, let task else { return }
        task.receive { [weak self] result in
            guard let self, !self.isClosed else { return }
            switch result {
            case .success(let message):
                self.handle(message)
                self.receiveNext()
            case .failure(let error):
                guard !self.isClosed else { return }
                self.delegateOnMain { $0.signalingError(error.localizedDescription) }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .string(let text): data = text.data(using: .utf8)
        case .data(let raw): data = raw
        @unknown default: data = nil
        }
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object[Wire.Key.type] as? String else { return }

        delegateOnMain { delegate in
            switch type {
            case Wire.Signal.peerJoined:
                delegate.signalingPeerJoined()
            case Wire.Signal.signal:
                if let data = object[Wire.Key.data] as? [String: Any] { delegate.signalingReceivedSignal(data) }
            case Wire.Signal.message:
                if let data = object[Wire.Key.data] as? [String: Any] { delegate.signalingReceivedMessage(data) }
            case Wire.Signal.peerLeft:
                delegate.signalingPeerLeft()
            case Wire.Signal.error:
                delegate.signalingError(object["reason"] as? String ?? "未知错误")
            default:
                break
            }
        }
    }

    private func delegateOnMain(_ block: @escaping (SignalingClientDelegate) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isClosed, let delegate = self.delegate else { return }
            block(delegate)
        }
    }
}
