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
import org.webrtc.RtpReceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.nio.charset.StandardCharsets

/** 远程窗口画面（2.0）的回调出口：把视频轨/缩略图/视口元数据交给上层 UI。 */
interface ScreenListener {
    fun onVideoTrack(track: VideoTrack)
    fun onThumbnail(sessionId: String, jpeg: ByteArray)
    fun onMeta(sessionId: String, winW: Int, winH: Int, scale: Float, x: Int, y: Int, w: Int, h: Int)
}

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

    /** 远程窗口画面（2.0）的回调出口：把视频轨/缩略图/视口元数据交给上层 UI。 */
    var screenListener: ScreenListener? = null
        set(value) {
            field = value
            // 注册时若视频轨已就绪，立即补发，避免 UI 漏接。
            remoteVideoTrack?.let { value?.onVideoTrack(it) }
        }

    private var remoteVideoTrack: VideoTrack? = null

    companion object {
        private var factory: PeerConnectionFactory? = null
        private var sharedEglBase: org.webrtc.EglBase? = null

        /** 渲染器需要与解码器共享同一 EGL 上下文。 */
        fun eglBaseContext(): org.webrtc.EglBase.Context? = sharedEglBase?.eglBaseContext

        private fun ensureFactory(context: Context): PeerConnectionFactory {
            if (factory == null) {
                PeerConnectionFactory.initialize(
                    PeerConnectionFactory.InitializationOptions.builder(context)
                        .createInitializationOptions()
                )
                val eglBase = org.webrtc.EglBase.create()
                sharedEglBase = eglBase
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

    // MARK: 远程窗口画面（2.0）

    /** 请求桌面端开始采集某会话窗口，并告知手机视口像素尺寸。 */
    fun startScreen(session: Session, viewportW: Int, viewportH: Int) {
        if (!isConnected) return
        val json = JSONObject()
            .put("type", "screen-start")
            .put("sessionId", session.id)
            .put("viewport", JSONObject().put("w", viewportW).put("h", viewportH))
        sendJson(json)
    }

    /** 通知桌面端停止采集。 */
    fun stopScreen(session: Session) {
        if (!isConnected) return
        val json = JSONObject()
            .put("type", "screen-stop")
            .put("sessionId", session.id)
        sendJson(json)
    }

    /** 拖动手机视口时上报采集区域（窗口像素坐标）。 */
    fun sendViewport(session: Session, x: Int, y: Int, w: Int, h: Int) {
        if (!isConnected) return
        val json = JSONObject()
            .put("type", "viewport")
            .put("sessionId", session.id)
            .put("x", x).put("y", y).put("w", w).put("h", h)
        sendJson(json)
    }

    // 触控转鼠标

    fun sendPointerDown(session: Session, x: Int, y: Int) {
        if (!isConnected) return
        sendJson(JSONObject().put("type", "pointer-down")
            .put("sessionId", session.id).put("x", x).put("y", y))
    }

    fun sendPointerUp(session: Session, x: Int, y: Int) {
        if (!isConnected) return
        sendJson(JSONObject().put("type", "pointer-up")
            .put("sessionId", session.id).put("x", x).put("y", y))
    }

    fun sendPointerScroll(session: Session, dx: Int, dy: Int) {
        if (!isConnected) return
        sendJson(JSONObject().put("type", "pointer-scroll")
            .put("sessionId", session.id).put("dx", dx).put("dy", dy))
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

            override fun onAddTrack(receiver: RtpReceiver, streams: Array<out org.webrtc.MediaStream>?) {
                val track = receiver.track()
                if (track is VideoTrack) {
                    remoteVideoTrack = track
                    screenListener?.onVideoTrack(track)
                }
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
                if (buffer.binary) {
                    handleBinaryFrame(bytes)
                } else {
                    handlePeerMessage(JSONObject(String(bytes, StandardCharsets.UTF_8)))
                }
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
            "session-input-lost" -> {
                val sid = msg.optString("sessionId")
                sessions.firstOrNull { it.id == sid }?.inputAvailable = false
                notifySessions()
            }
            "screen-meta" -> handleScreenMeta(msg)
        }
    }

    private fun handleScreenMeta(msg: JSONObject) {
        val listener = screenListener ?: return
        val sessionId = msg.optString("sessionId")
        val win = msg.optJSONObject("win") ?: return
        val applied = msg.optJSONObject("applied") ?: return
        listener.onMeta(
            sessionId,
            win.optInt("w"), win.optInt("h"),
            win.optDouble("scale", 2.0).toFloat(),
            applied.optInt("x"), applied.optInt("y"),
            applied.optInt("w"), applied.optInt("h")
        )
    }

    /** 缩略图二进制帧：`[2 字节大端 sessionId 长度][sessionId UTF-8][JPEG]`。 */
    private fun handleBinaryFrame(bytes: ByteArray) {
        val listener = screenListener ?: return
        if (bytes.size < 2) return
        val idLen = ((bytes[0].toInt() and 0xFF) shl 8) or (bytes[1].toInt() and 0xFF)
        if (idLen < 0 || 2 + idLen > bytes.size) return
        val sessionId = String(bytes, 2, idLen, StandardCharsets.UTF_8)
        val jpeg = bytes.copyOfRange(2 + idLen, bytes.size)
        listener.onThumbnail(sessionId, jpeg)
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
            val idx = sessions.indexOf(existing)
            val updated = existing.copy(
                app = msg.optString("app"),
                title = msg.optString("title"),
                device = if (device.isNotBlank()) device else existing.device,
                isActive = true,
                inputAvailable = true
            )
            updated.messages.addAll(existing.messages)
            if (device.isNotBlank()) existing.device = device
            if (idx >= 0) {
                sessions.removeAt(idx)
            }
            sessions.add(0, updated)
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
        remoteVideoTrack = null
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
    override fun onAddTrack(receiver: RtpReceiver, streams: Array<out org.webrtc.MediaStream>?) {}
    override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {}
}
