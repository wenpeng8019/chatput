package com.chatput.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.json.JSONArray
import org.json.JSONObject

object ConnectionManager {

    interface Observer {
        fun onStatus(connectionId: String, status: String, connected: Boolean)
        fun onSessionsChanged(connectionId: String)
        fun onMessage(connectionId: String, sessionId: String, msg: ChatMessage)
    }

    data class Pairing(val label: String, val payload: String)

    data class ConnectedDesktop(
        val connectionId: String,
        val label: String,
        val transportLabel: String
    )

    private const val PREF_NAME = "chatput_prefs"
    private const val KEY_RECENT = "recent_pairings"

    private val main = Handler(Looper.getMainLooper())
    private val observers = mutableSetOf<Observer>()
    private val connections = linkedMapOf<String, DesktopConnection>()

    val sessions = mutableListOf<Session>()

    var status: String = "未连接"
        private set

    val isConnected: Boolean
        get() = connections.values.any { it.isConnected }

    val isConnecting: Boolean
        get() = connections.values.any { it.isConnecting }

    val hasConnectionContext: Boolean
        get() = isConnected

    private var appContext: Context? = null
    private var lastStatusMessage = "未连接"

    fun addObserver(observer: Observer) {
        observers.add(observer)
    }

    fun removeObserver(observer: Observer) {
        observers.remove(observer)
    }

    fun pairWith(context: Context, qrPayload: String) {
        appContext = context.applicationContext
        val connectionId = connectionIdFromPayload(qrPayload)
        connections.remove(connectionId)?.disconnect()

        val connection = DesktopConnection(
            connectionId = connectionId,
            qrPayload = qrPayload,
            appContext = context.applicationContext,
            onStatusChanged = ::handleConnectionStatus,
            onSessionsChanged = ::handleConnectionSessionsChanged,
            onMessage = ::handleConnectionMessage,
            onConnected = ::handleConnectionConnected,
            onLabelChanged = ::handleConnectionLabelChanged,
            onPairingExpired = ::handlePairingExpired
        )
        connections[connectionId] = connection
        recomputeAggregateStatus()
        rebuildSessions()
        connection.connect()
    }

    fun sessionById(connectionId: String, sessionId: String): Session? {
        return connections[connectionId]?.sessionById(sessionId)
    }

    fun connectedConnections(): List<ConnectedDesktop> {
        return connections.values
            .filter { it.isConnected }
            .map {
                ConnectedDesktop(
                    connectionId = it.connectionId,
                    label = it.connectionLabel,
                    transportLabel = it.transportLabel
                )
            }
    }

    fun connectionGroupLabel(): String {
        val connected = connectedConnections()
        return when {
            connected.size > 1 -> "已连接 ${connected.size} 台桌面"
            connected.size == 1 -> connected.first().transportLabel
            isConnecting -> "连接中"
            else -> "桌面连接"
        }
    }

    fun sendText(session: Session, text: String) {
        connections[session.connectionId]?.sendText(session, text)
    }

    fun resendText(session: Session, text: String) {
        connections[session.connectionId]?.resendText(session, text)
    }

    fun sendAction(session: Session, action: String) {
        connections[session.connectionId]?.sendAction(session, action)
    }

    fun disconnect(connectionId: String? = null) {
        if (connectionId == null) {
            val allIds = connections.keys.toList()
            allIds.forEach { id ->
                connections.remove(id)?.disconnect()
            }
        } else {
            connections.remove(connectionId)?.disconnect()
        }
        rebuildSessions()
        recomputeAggregateStatus()
    }

    fun recentPairings(context: Context): List<Pairing> {
        val sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        val raw = sp.getString(KEY_RECENT, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            (0 until arr.length()).map {
                val obj = arr.getJSONObject(it)
                Pairing(obj.getString("label"), obj.getString("payload"))
            }
        } catch (_: Exception) {
            emptyList()
        }
    }

    fun removeRecentPairing(context: Context, payload: String) {
        appContext = context.applicationContext
        removePairing(connectionIdFromPayload(payload))
    }

    private fun handleConnectionStatus(connectionId: String, connectionStatus: String, connected: Boolean) {
        lastStatusMessage = connectionStatus
        pruneInactiveConnections()
        rebuildSessions()
        recomputeAggregateStatus()
        main.post { observers.forEach { it.onStatus(connectionId, connectionStatus, connected) } }
    }

    private fun handleConnectionSessionsChanged(connectionId: String) {
        pruneInactiveConnections()
        rebuildSessions()
        recomputeAggregateStatus()
        main.post { observers.forEach { it.onSessionsChanged(connectionId) } }
    }

    private fun handleConnectionMessage(connectionId: String, sessionId: String, msg: ChatMessage) {
        main.post { observers.forEach { it.onMessage(connectionId, sessionId, msg) } }
    }

    @Suppress("UNUSED_PARAMETER")
    private fun handleConnectionConnected(_connectionId: String, qrPayload: String) {
        val ctx = appContext ?: return
        savePairing(ctx, qrPayload)
    }

    private fun handleConnectionLabelChanged(connectionId: String, deviceName: String) {
        val ctx = appContext ?: return
        if (deviceName.isBlank()) return
        val payload = recentPairings(ctx)
            .firstOrNull { pairingKey(it.payload) == connectionId }
            ?.payload ?: return
        savePairing(ctx, payload, deviceName)
    }

    private fun handlePairingExpired(connectionId: String, reason: String): Boolean {
        if (reason != "room-not-found" && reason != "bad-token") return false
        removePairing(connectionId)
        return true
    }

    private fun rebuildSessions() {
        sessions.clear()
        connections.values.forEach { sessions.addAll(it.sessions) }
    }

    private fun recomputeAggregateStatus() {
        val connectedConnections = connections.values.filter { it.isConnected }
        val connectingConnections = connections.values.filter { it.isConnecting }
        status = when {
            connectedConnections.size > 1 -> "已连接 ${connectedConnections.size} 台桌面"
            connectedConnections.size == 1 -> connectedConnections.first().status
            connectingConnections.isNotEmpty() -> connectingConnections.first().status
            else -> lastStatusMessage
        }
    }

    private fun pruneInactiveConnections() {
        val staleIds = connections.values
            .filter { !it.isConnected && !it.isConnecting && it.sessions.isEmpty() }
            .map { it.connectionId }
        staleIds.forEach { connections.remove(it) }
    }

    private fun savePairing(context: Context, payload: String, label: String? = null) {
        val key = pairingKey(payload) ?: return
        val data = JSONObject(payload)
        val roomId = data.optString("roomId")
        val existing = recentPairings(context).filterNot { pairingKey(it.payload) == key }
        val entry = Pairing(label ?: "房间 $roomId", payload)
        val updated = (listOf(entry) + existing).take(3)
        val arr = JSONArray()
        updated.forEach { arr.put(JSONObject().put("label", it.label).put("payload", it.payload)) }
        context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_RECENT, arr.toString())
            .apply()
    }

    private fun removePairing(connectionId: String) {
        val ctx = appContext ?: return
        val updated = recentPairings(ctx).filterNot { pairingKey(it.payload) == connectionId }
        val arr = JSONArray()
        updated.forEach { arr.put(JSONObject().put("label", it.label).put("payload", it.payload)) }
        ctx.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_RECENT, arr.toString())
            .apply()
    }

    private fun connectionIdFromPayload(payload: String): String {
        val data = JSONObject(payload)
        return buildConnectionId(data.getString("url"), data.getString("roomId"))
    }

    private fun pairingKey(payload: String): String? {
        return runCatching { connectionIdFromPayload(payload) }.getOrNull()
    }

    internal fun buildConnectionId(url: String, roomId: String): String = "$url|$roomId"
}
