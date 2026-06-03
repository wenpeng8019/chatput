package com.chatput.app

import android.content.Context
import org.json.JSONObject
import org.webrtc.DataChannel
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

internal class DesktopConnection(
    val connectionId: String,
    private val qrPayload: String,
    private val appContext: Context,
    private val onStatusChanged: (String, String, Boolean) -> Unit,
    private val onSessionsChanged: (String) -> Unit,
    private val onMessage: (String, String, ChatMessage) -> Unit,
    private val onConnected: (String, String) -> Unit,
    private val onLabelChanged: (String, String) -> Unit,
    private val onPairingExpired: (String, String) -> Boolean
) : SignalingClient.Listener {

    private enum class TransportMode {
        WEBRTC,
        WEBSOCKET;

        companion object {
            fun from(raw: String): TransportMode {
                return if (raw.equals("websocket", ignoreCase = true)) WEBSOCKET else WEBRTC
            }
        }
    }

    companion object {
        private var factory: PeerConnectionFactory? = null

        private fun ensureFactory(context: Context): PeerConnectionFactory {
            if (factory == null) {
                PeerConnectionFactory.initialize(
                    PeerConnectionFactory.InitializationOptions.builder(context)
                        .createInitializationOptions()
                )
                val eglBase = org.webrtc.EglBase.create()
                factory = PeerConnectionFactory.builder()
                    .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true))
                    .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
                    .createPeerConnectionFactory()
            }
            return factory!!
        }
    }

    private val payload = JSONObject(qrPayload)
    private val url = payload.getString("url")
    private val roomId = payload.getString("roomId")
    private val token = payload.getString("token")
    private val transportMode = TransportMode.from(payload.optString("transport", "webrtc"))
    private val iceServers = listOf(
        PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer()
    )

    val sessions = mutableListOf<Session>()

    var status: String = "未连接"
        private set
    var isConnected: Boolean = false
        private set
    var isConnecting: Boolean = false
        private set

    val connectionLabel: String
        get() = deviceLabel.ifBlank { "房间 $roomId" }

    val transportLabel: String
        get() = when (transportMode) {
            TransportMode.WEBRTC -> "P2P 连接"
            TransportMode.WEBSOCKET -> "WS 连接"
        }

    private var signalingReady = false
    private var manualDisconnectInProgress = false
    private var releasingTransports = false
    private var pc: PeerConnection? = null
    private var dataChannel: DataChannel? = null
    private var signaling: SignalingClient? = null
    private var deviceLabel: String = ""

    fun connect() {
        manualDisconnectInProgress = false
        releaseTransports()
        isConnecting = true
        signalingReady = false
        isConnected = false

        if (transportMode == TransportMode.WEBRTC) {
            ensureFactory(appContext)
        }

        updateStatus("连接信令服务器…", false)
        signaling = SignalingClient(url, this)
        signaling!!.connect(roomId, token)
    }

    fun sessionById(sessionId: String): Session? = sessions.firstOrNull { it.id == sessionId }

    fun sendText(session: Session, text: String) {
        if (text.isBlank() || !isConnected) return
        val json = JSONObject()
            .put("type", "text")
            .put("text", text)
            .put("sessionId", session.id)
        sendJson(json)

        val msg = ChatMessage(text, fromMe = true)
        session.messages.add(msg)
        onMessage(connectionId, session.id, msg)
    }

    fun resendText(session: Session, text: String) {
        if (text.isBlank() || !isConnected) return
        val json = JSONObject()
            .put("type", "text")
            .put("text", text)
            .put("sessionId", session.id)
        sendJson(json)
    }

    fun sendAction(session: Session, action: String) {
        if (!isConnected) return
        val json = JSONObject()
            .put("type", "action")
            .put("action", action)
            .put("sessionId", session.id)
        sendJson(json)
    }

    fun disconnect() {
        manualDisconnectInProgress = true
        releaseTransports()
        signalingReady = false
        isConnecting = false
        isConnected = false
        clearSessions()
        updateStatus("未连接", false)
    }

    override fun onPeerJoined() {
        if (transportMode == TransportMode.WEBSOCKET) {
            signalingReady = true
            markConnected("WebSocket 已连接")
            sendHello()
        } else {
            updateStatus("配对成功，正在建立连接…", false)
            createPeerConnection()
        }
    }

    override fun onSignal(data: JSONObject) {
        if (transportMode != TransportMode.WEBRTC) return
        if (data.has("sdp")) {
            val sdp = data.getJSONObject("sdp")
            val type = SessionDescription.Type.fromCanonicalForm(sdp.getString("type"))
            val desc = SessionDescription(type, sdp.getString("sdp"))
            pc?.setRemoteDescription(object : SimpleSdpObserver() {
                override fun onSetSuccess() {
                    createAnswer()
                }
            }, desc)
        } else if (data.has("candidate")) {
            val candidate = data.getJSONObject("candidate")
            pc?.addIceCandidate(
                IceCandidate(
                    candidate.optString("sdpMid"),
                    candidate.optInt("sdpMLineIndex"),
                    candidate.getString("candidate")
                )
            )
        }
    }

    override fun onAppMessage(data: JSONObject) {
        handlePeerMessage(data)
    }

    override fun onPeerLeft() {
        if (manualDisconnectInProgress) return
        handleRemoteDisconnected("桌面端已断开")
    }

    override fun onError(reason: String) {
        if (manualDisconnectInProgress) return
        releaseTransports()
        signalingReady = false
        isConnecting = false
        clearSessions()
        if (onPairingExpired(connectionId, reason)) {
            updateStatus("历史连接已失效，请重新扫码", false)
        } else {
            updateStatus("错误: $reason", false)
        }
    }

    override fun onClosed() {
        if (manualDisconnectInProgress) return
        handleRemoteDisconnected("桌面断开")
    }

    private fun updateStatus(statusText: String, connected: Boolean = isConnected) {
        status = statusText
        isConnected = connected
        onStatusChanged(connectionId, statusText, connected)
    }

    private fun notifySessions() {
        onSessionsChanged(connectionId)
    }

    private fun markConnected(statusText: String) {
        val wasConnected = isConnected
        isConnecting = false
        isConnected = true
        if (!wasConnected) onConnected(connectionId, qrPayload)
        updateStatus(statusText, true)
    }

    private fun createPeerConnection() {
        val rtcConfig = PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        }
        pc = ensureFactory(appContext).createPeerConnection(rtcConfig, object : SimplePcObserver() {
            override fun onIceCandidate(candidate: IceCandidate) {
                val c = JSONObject()
                    .put("candidate", candidate.sdp)
                    .put("sdpMid", candidate.sdpMid)
                    .put("sdpMLineIndex", candidate.sdpMLineIndex)
                signaling?.sendSignal(JSONObject().put("candidate", c))
            }

            override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
                if (manualDisconnectInProgress) return
                when (newState) {
                    PeerConnection.PeerConnectionState.CONNECTED -> markConnected("P2P 已连接")
                    PeerConnection.PeerConnectionState.DISCONNECTED,
                    PeerConnection.PeerConnectionState.FAILED,
                    PeerConnection.PeerConnectionState.CLOSED -> handleRemoteDisconnected("桌面断开")
                    else -> Unit
                }
            }

            override fun onDataChannel(dataChannel: DataChannel) {
                this@DesktopConnection.dataChannel = dataChannel
                wireChannel(dataChannel)
            }
        })
    }

    private fun createAnswer() {
        pc?.createAnswer(object : SimpleSdpObserver() {
            override fun onCreateSuccess(desc: SessionDescription) {
                pc?.setLocalDescription(object : SimpleSdpObserver() {
                    override fun onSetSuccess() {
                        val sdp = JSONObject()
                            .put("type", desc.type.canonicalForm())
                            .put("sdp", desc.description)
                        signaling?.sendSignal(JSONObject().put("sdp", sdp))
                    }
                }, desc)
            }
        }, MediaConstraints())
    }

    private fun wireChannel(channel: DataChannel) {
        channel.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) {}

            override fun onStateChange() {
                val state = channel.state()
                val open = state == DataChannel.State.OPEN
                if (open) {
                    markConnected("P2P 已连接")
                    sendHello()
                }
                if (!manualDisconnectInProgress && (state == DataChannel.State.CLOSING || state == DataChannel.State.CLOSED)) {
                    handleRemoteDisconnected("桌面断开")
                }
            }

            override fun onMessage(buffer: DataChannel.Buffer) {
                val bytes = ByteArray(buffer.data.remaining())
                buffer.data.get(bytes)
                val text = String(bytes, StandardCharsets.UTF_8)
                handlePeerMessage(JSONObject(text))
            }
        })
    }

    private fun sendHello() {
        val json = JSONObject()
            .put("type", "hello")
            .put("device", deviceName())
        sendJson(json)
    }

    private fun deviceName(): String {
        val custom = try {
            android.provider.Settings.Global.getString(appContext.contentResolver, "device_name")
        } catch (_: Exception) {
            null
        }
        if (!custom.isNullOrBlank()) return custom
        val manufacturer = android.os.Build.MANUFACTURER?.replaceFirstChar { it.uppercase() } ?: ""
        val model = android.os.Build.MODEL ?: "Android"
        return if (model.startsWith(manufacturer, ignoreCase = true)) model else "$manufacturer $model".trim()
    }

    private fun sendJson(json: JSONObject) {
        if (transportMode == TransportMode.WEBSOCKET) {
            signaling?.sendMessage(json)
        } else {
            val buffer = ByteBuffer.wrap(json.toString().toByteArray(StandardCharsets.UTF_8))
            dataChannel?.send(DataChannel.Buffer(buffer, false))
        }
    }

    private fun handlePeerMessage(msg: JSONObject) {
        when (msg.optString("type")) {
            "session" -> upsertSession(msg)
            "session-closed" -> removeSession(msg.optString("sessionId"))
        }
    }

    private fun upsertSession(msg: JSONObject) {
        val sessionId = msg.getString("sessionId")
        val device = msg.optString("device")
        if (device.isNotBlank()) {
            deviceLabel = device
            onLabelChanged(connectionId, device)
        }

        sessions.forEach { it.isActive = false }
        val existing = sessions.firstOrNull { it.id == sessionId }
        if (existing == null) {
            sessions.add(
                0,
                Session(
                    connectionId = connectionId,
                    id = sessionId,
                    app = msg.optString("app"),
                    title = msg.optString("title"),
                    device = device,
                    isActive = true
                )
            )
        } else {
            if (device.isNotBlank()) existing.device = device
            existing.isActive = true
            if (sessions.indexOf(existing) != 0) {
                sessions.remove(existing)
                sessions.add(0, existing)
            }
        }
        notifySessions()
    }

    private fun removeSession(sessionId: String) {
        if (sessionId.isBlank()) return
        val removed = sessions.removeAll { it.id == sessionId }
        if (!removed) return
        if (sessions.none { it.isActive }) {
            sessions.firstOrNull()?.isActive = true
        }
        notifySessions()
    }

    private fun handleRemoteDisconnected(message: String) {
        if (manualDisconnectInProgress || releasingTransports) return
        releaseTransports()
        signalingReady = false
        isConnecting = false
        isConnected = false
        clearSessions()
        updateStatus(message, false)
    }

    private fun releaseTransports() {
        if (releasingTransports) return
        releasingTransports = true

        val channel = dataChannel
        val peer = pc
        val signalingClient = signaling

        dataChannel = null
        pc = null
        signaling = null
        isConnecting = false

        try {
            channel?.close()
        } catch (_: Exception) {
        }
        try {
            peer?.close()
        } catch (_: Exception) {
        }
        try {
            signalingClient?.close()
        } catch (_: Exception) {
        }

        releasingTransports = false
    }

    private fun clearSessions() {
        if (sessions.isEmpty()) return
        sessions.clear()
        notifySessions()
    }
}

open class SimpleSdpObserver : SdpObserver {
    override fun onCreateSuccess(desc: SessionDescription) {}
    override fun onSetSuccess() {}
    override fun onCreateFailure(error: String?) {}
    override fun onSetFailure(error: String?) {}
}

open class SimplePcObserver : PeerConnection.Observer {
    override fun onSignalingChange(newState: PeerConnection.SignalingState?) {}
    override fun onIceConnectionChange(newState: PeerConnection.IceConnectionState?) {}
    override fun onIceConnectionReceivingChange(receiving: Boolean) {}
    override fun onIceGatheringChange(newState: PeerConnection.IceGatheringState?) {}
    override fun onIceCandidate(candidate: IceCandidate) {}
    override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}
    override fun onAddStream(stream: org.webrtc.MediaStream?) {}
    override fun onRemoveStream(stream: org.webrtc.MediaStream?) {}
    override fun onDataChannel(dataChannel: DataChannel) {}
    override fun onRenegotiationNeeded() {}
    override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {}
}
