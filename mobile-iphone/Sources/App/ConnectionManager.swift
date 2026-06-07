import Foundation

@MainActor
final class ConnectionManager: ObservableObject {
    @Published private(set) var sessions: [DesktopSession] = []
    @Published private(set) var status = "未连接"

    private let recentKey = "recent_pairings"
    private var connections: [String: DesktopConnection] = [:]
    private var connectionOrder: [String] = []
    private var lastStatusMessage = "未连接"

    var isConnected: Bool { connections.values.contains { $0.isConnected } }
    var isConnecting: Bool { connections.values.contains { $0.isConnecting } }
    var hasConnectionContext: Bool { isConnected }

    /// 某条历史连接当前是否正在连接中（用于每行独立的加载动画，支持多个并行连接）。
    func isConnecting(connectionId: String) -> Bool {
        connections[connectionId]?.isConnecting ?? false
    }

    func pair(rawPayload: String) throws {
        let data = Data(rawPayload.utf8)
        let payload = try JSONDecoder().decode(QRPairingPayload.self, from: data)
        pair(payload)
    }

    func pair(_ payload: QRPairingPayload) {
        let connectionId = payload.connectionId
        connections.removeValue(forKey: connectionId)?.disconnect()
        connectionOrder.removeAll { $0 == connectionId }

        let connection = DesktopConnection(payload: payload)
        connection.onStatusChanged = { [weak self] id, status, connected in
            Task { @MainActor in self?.handleStatus(connectionId: id, status: status, connected: connected) }
        }
        connection.onSessionsChanged = { [weak self] id in
            Task { @MainActor in self?.handleSessionsChanged(connectionId: id) }
        }
        connection.onMessage = { [weak self] id, sessionId, message in
            Task { @MainActor in self?.handleMessage(connectionId: id, sessionId: sessionId, message: message) }
        }
        connection.onConnected = { [weak self] _, payload in
            Task { @MainActor in self?.saveRecent(payload: payload) }
        }
        connection.onLabelChanged = { [weak self] id, label in
            Task { @MainActor in self?.updateRecentLabel(connectionId: id, label: label) }
        }
        connection.onPairingExpired = { [weak self] id, reason in
            var expired = false
            Task { @MainActor in
                expired = reason == Wire.Reason.roomNotFound || reason == Wire.Reason.badToken
                if expired { self?.removeRecent(connectionId: id) }
            }
            return reason == Wire.Reason.roomNotFound || reason == Wire.Reason.badToken
        }
        connections[connectionId] = connection
        connectionOrder.append(connectionId)
        rebuildSessions()
        recomputeStatus()
        connection.connect()
    }

    func session(connectionId: String, sessionId: String) -> DesktopSession? {
        connections[connectionId]?.sessionById(sessionId)
    }

    func sendText(session: DesktopSession, text: String) {
        connections[session.connectionId]?.sendText(session: session, text: text)
        rebuildSessions()
    }

    func resendText(session: DesktopSession, text: String) {
        connections[session.connectionId]?.resendText(session: session, text: text)
    }

    func sendAction(session: DesktopSession, action: String) {
        connections[session.connectionId]?.sendAction(session: session, action: action)
    }

    func setScreenListener(connectionId: String, listener: ScreenListener?) {
        connections[connectionId]?.screenListener = listener
    }

    func startScreen(session: DesktopSession, viewportW: Int, viewportH: Int) {
        connections[session.connectionId]?.startScreen(session: session, viewportW: viewportW, viewportH: viewportH)
    }

    func stopScreen(session: DesktopSession) {
        connections[session.connectionId]?.stopScreen(session: session)
    }

    func sendViewport(session: DesktopSession, x: Int, y: Int, w: Int, h: Int) {
        connections[session.connectionId]?.sendViewport(session: session, x: x, y: y, w: w, h: h)
    }

    func sendPointerDown(session: DesktopSession, x: Int, y: Int) {
        connections[session.connectionId]?.sendPointerDown(session: session, x: x, y: y)
    }

    func sendPointerUp(session: DesktopSession, x: Int, y: Int) {
        connections[session.connectionId]?.sendPointerUp(session: session, x: x, y: y)
    }

    func sendPointerScroll(session: DesktopSession, dx: Int, dy: Int) {
        connections[session.connectionId]?.sendPointerScroll(session: session, dx: dx, dy: dy)
    }

    func deleteMessage(session: DesktopSession, at index: Int) {
        guard var desktopSessions = connections[session.connectionId]?.sessions,
              let sessionIndex = desktopSessions.firstIndex(where: { $0.sessionId == session.sessionId }),
              desktopSessions[sessionIndex].messages.indices.contains(index) else { return }
        desktopSessions[sessionIndex].messages.remove(at: index)
        connections[session.connectionId]?.sessions = desktopSessions
        rebuildSessions()
    }

    func disconnect(_ connectionId: String? = nil) {
        if let connectionId {
            connections.removeValue(forKey: connectionId)?.disconnect()
            connectionOrder.removeAll { $0 == connectionId }
        } else {
            connections.values.forEach { $0.disconnect() }
            connections.removeAll()
            connectionOrder.removeAll()
        }
        rebuildSessions()
        recomputeStatus()
    }

    func connectedDesktops() -> [ConnectedDesktop] {
        connectionOrder.compactMap { id in
            guard let connection = connections[id], connection.isConnected else { return nil }
            return ConnectedDesktop(id: id, label: connection.connectionLabel, transportLabel: connection.transportLabel)
        }
    }

    func connectionGroupLabel() -> String {
        let connected = connectedDesktops()
        if connected.count > 1 { return "已连接 \(connected.count) 台桌面" }
        if let one = connected.first { return one.transportLabel }
        if isConnecting { return "连接中" }
        return "桌面连接"
    }

    func recentPairings() -> [Pairing] {
        guard let data = UserDefaults.standard.data(forKey: recentKey),
              let pairings = try? JSONDecoder().decode([Pairing].self, from: data) else { return [] }
        return pairings
    }

    func removeRecent(payload: QRPairingPayload) {
        removeRecent(connectionId: payload.connectionId)
    }

    private func handleStatus(connectionId: String, status: String, connected: Bool) {
        lastStatusMessage = status
        pruneInactiveConnections()
        rebuildSessions()
        recomputeStatus()
    }

    private func handleSessionsChanged(connectionId: String) {
        pruneInactiveConnections()
        rebuildSessions()
        recomputeStatus()
    }

    private func handleMessage(connectionId: String, sessionId: String, message: ChatMessage) {
        rebuildSessions()
    }

    private func rebuildSessions() {
        sessions = connectionOrder.compactMap { connections[$0] }.flatMap { $0.sessions }
    }

    private func recomputeStatus() {
        let connected = connectionOrder.compactMap { connections[$0] }.filter { $0.isConnected }
        let connecting = connectionOrder.compactMap { connections[$0] }.filter { $0.isConnecting }
        if connected.count > 1 {
            status = "已连接 \(connected.count) 台桌面"
        } else if let one = connected.first {
            status = one.status
        } else if let one = connecting.first {
            status = one.status
        } else {
            status = lastStatusMessage
        }
    }

    private func pruneInactiveConnections() {
        let stale = connections.values
            .filter { !$0.isConnected && !$0.isConnecting && $0.sessions.isEmpty }
            .map(\.connectionId)
        stale.forEach { id in
            connections.removeValue(forKey: id)
            connectionOrder.removeAll { $0 == id }
        }
    }

    private func saveRecent(payload: QRPairingPayload, label: String? = nil) {
        let existing = recentPairings().filter { $0.payload.connectionId != payload.connectionId }
        let entry = Pairing(label: label ?? "房间 \(payload.roomId)", payload: payload)
        persistRecent(Array(([entry] + existing).prefix(3)))
    }

    private func updateRecentLabel(connectionId: String, label: String) {
        guard let pairing = recentPairings().first(where: { $0.payload.connectionId == connectionId }) else { return }
        saveRecent(payload: pairing.payload, label: label)
    }

    private func removeRecent(connectionId: String) {
        persistRecent(recentPairings().filter { $0.payload.connectionId != connectionId })
    }

    private func persistRecent(_ pairings: [Pairing]) {
        guard let data = try? JSONEncoder().encode(pairings) else { return }
        UserDefaults.standard.set(data, forKey: recentKey)
    }
}
