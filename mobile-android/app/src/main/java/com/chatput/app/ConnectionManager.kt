package com.chatput.app

import android.content.Context
import android.os.Handler
import android.os.Looper
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

/**
 * 手机端 = WebRTC GUEST。
 * 通过信令服务器加入房间，应答桌面端(HOST)的 offer，建立 P2P DataChannel。
 * 接收 session 消息（每个桌面输入窗口一个），发送语音识别得到的 text 消息。
 *
 * 单例，跨 Activity 复用同一连接。
 */
object ConnectionManager : SignalingClient.Listener {

    private enum class TransportMode {
        WEBRTC,
        WEBSOCKET;

        companion object {
            fun from(raw: String): TransportMode {
                return if (raw.equals("websocket", ignoreCase = true)) WEBSOCKET else WEBRTC
            }
        }
    }

    interface Observer {
        fun onStatus(status: String, connected: Boolean)
        fun onSessionsChanged()
        fun onMessage(sessionId: String, msg: ChatMessage)
    }

    private val main = Handler(Looper.getMainLooper())
    private val observers = mutableSetOf<Observer>()

    val sessions = mutableListOf<Session>()
    /** 桌面端当前聚焦的会话 id（焦点切换时由桌面端通知）。 */
    var activeSessionId: String? = null
        private set
    var status: String = "未连接"
        private set
    val isConnected: Boolean
        get() = connectedState

    private var factory: PeerConnectionFactory? = null
    private var pc: PeerConnection? = null
    private var dataChannel: DataChannel? = null
    private var signaling: SignalingClient? = null
    private var appContext: Context? = null
    private var transportMode = TransportMode.WEBRTC
    private var signalingReady = false
    private var connectedState = false

    private val iceServers = listOf(
        PeerConnection.IceServer.builder("stun:stun.l.google.com:19302").createIceServer()
    )

    fun addObserver(o: Observer) {
        observers.add(o)
    }

    fun removeObserver(o: Observer) {
        observers.remove(o)
    }

    private fun setStatus(s: String, connected: Boolean = isConnected) {
        status = s
        connectedState = connected
        main.post { observers.forEach { it.onStatus(s, connected) } }
    }

    private fun notifySessions() {
        main.post { observers.forEach { it.onSessionsChanged() } }
    }

    fun sessionById(id: String): Session? = sessions.firstOrNull { it.id == id }

    fun connectionGroupLabel(): String = when (transportMode) {
        TransportMode.WEBRTC -> "P2P 连接"
        TransportMode.WEBSOCKET -> "WS 连接"
    }

    fun connectedDeviceNames(): List<String> {
        val names = sessions
            .mapNotNull { it.device.takeIf { name -> name.isNotBlank() } }
            .distinct()
        return names.ifEmpty { listOf("桌面设备") }
    }

    /**
     * 用扫码得到的 JSON 配对： {"url":"ws://...:8080","roomId":"...","token":"..."}
     */
    fun pairWith(context: Context, qrPayload: String) {
        appContext = context.applicationContext

        val data = JSONObject(qrPayload)
        val url = data.getString("url")
        val roomId = data.getString("roomId")
        val token = data.getString("token")
        transportMode = TransportMode.from(data.optString("transport", "webrtc"))
        connectedState = false
        signalingReady = false

        lastPairedRoomId = roomId
        savePairing(context, qrPayload, roomId)

        if (transportMode == TransportMode.WEBRTC) {
            ensureFactory()
        }

        setStatus("连接信令服务器…", false)
        signaling = SignalingClient(url, this)
        signaling!!.connect(roomId, token)
    }

    // --- 历史连接记录（最多 3 个，点击可免扫码重连） --------------------------

    /** 一条历史连接：label 为可读设备名，payload 为可直接用于 [pairWith] 的二维码 JSON。 */
    data class Pairing(val label: String, val payload: String)

    private const val PREF_NAME = "chatput_prefs"
    private const val KEY_RECENT = "recent_pairings"
    private var lastPairedRoomId: String? = null

    fun recentPairings(context: Context): List<Pairing> {
        val sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        val raw = sp.getString(KEY_RECENT, null) ?: return emptyList()
        return try {
            val arr = org.json.JSONArray(raw)
            (0 until arr.length()).map {
                val o = arr.getJSONObject(it)
                Pairing(o.getString("label"), o.getString("payload"))
            }
        } catch (e: Exception) {
            emptyList()
        }
    }

    /** 记录/置顶一条历史连接，按 roomId 去重，最多保留 3 条。 */
    private fun savePairing(context: Context, payload: String, roomId: String, label: String? = null) {
        val sp = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
        val existing = recentPairings(context).filterNot {
            runCatching { JSONObject(it.payload).optString("roomId") == roomId }.getOrDefault(false)
        }
        val entry = Pairing(label ?: "房间 $roomId", payload)
        val updated = (listOf(entry) + existing).take(3)
        val arr = org.json.JSONArray()
        updated.forEach { arr.put(JSONObject().put("label", it.label).put("payload", it.payload)) }
        sp.edit().putString(KEY_RECENT, arr.toString()).apply()
    }

    private fun removePairing(roomId: String) {
        val ctx = appContext ?: return
        val updated = recentPairings(ctx).filterNot {
            runCatching { JSONObject(it.payload).optString("roomId") == roomId }.getOrDefault(false)
        }
        val arr = org.json.JSONArray()
        updated.forEach { arr.put(JSONObject().put("label", it.label).put("payload", it.payload)) }
        ctx.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_RECENT, arr.toString())
            .apply()
        if (lastPairedRoomId == roomId) lastPairedRoomId = null
        notifySessions()
    }

    private fun removeLastPairingIfExpired(reason: String): Boolean {
        if (reason != "room-not-found" && reason != "bad-token") return false
        val roomId = lastPairedRoomId ?: return false
        removePairing(roomId)
        return true
    }

    /** 连接成功后用桌面端真实设备名更新对应历史记录的显示名。 */
    private fun updatePairingLabel(roomId: String, deviceName: String) {
        val ctx = appContext ?: return
        if (deviceName.isBlank()) return
        val payload = recentPairings(ctx)
            .firstOrNull { runCatching { JSONObject(it.payload).optString("roomId") == roomId }.getOrDefault(false) }
            ?.payload ?: return
        savePairing(ctx, payload, roomId, deviceName)
    }


    private fun ensureFactory() {
        if (factory != null) return
        val ctx = appContext ?: return
        PeerConnectionFactory.initialize(
            PeerConnectionFactory.InitializationOptions.builder(ctx)
                .createInitializationOptions()
        )
        val eglBase = org.webrtc.EglBase.create()
        factory = PeerConnectionFactory.builder()
            .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, true, true))
            .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
            .createPeerConnectionFactory()
    }

    // --- SignalingClient.Listener ------------------------------------------

    override fun onPeerJoined() {
        if (transportMode == TransportMode.WEBSOCKET) {
            signalingReady = true
            setStatus("WebSocket 已连接", true)
            sendHello()
        } else {
            setStatus("配对成功，正在建立连接…", false)
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
                    // GUEST：应答 HOST 的 offer
                    createAnswer()
                }
            }, desc)
        } else if (data.has("candidate")) {
            val c = data.getJSONObject("candidate")
            val candidate = IceCandidate(
                c.optString("sdpMid"),
                c.optInt("sdpMLineIndex"),
                c.getString("candidate")
            )
            pc?.addIceCandidate(candidate)
        }
    }

    override fun onAppMessage(data: JSONObject) {
        handlePeerMessage(data)
    }

    override fun onPeerLeft() {
        handleRemoteDisconnected("桌面端已断开")
    }

    override fun onError(reason: String) {
        signalingReady = false
        clearSessions()
        if (removeLastPairingIfExpired(reason)) {
            setStatus("历史连接已失效，请重新扫码", false)
        } else {
            setStatus("错误: $reason", false)
        }
    }

    override fun onClosed() {
        handleRemoteDisconnected("桌面断开")
    }

    // --- WebRTC ------------------------------------------------------------

    private fun createPeerConnection() {
        val rtcConfig = PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
        }
        pc = factory?.createPeerConnection(rtcConfig, object : SimplePcObserver() {
            override fun onIceCandidate(candidate: IceCandidate) {
                val c = JSONObject()
                    .put("candidate", candidate.sdp)
                    .put("sdpMid", candidate.sdpMid)
                    .put("sdpMLineIndex", candidate.sdpMLineIndex)
                signaling?.sendSignal(JSONObject().put("candidate", c))
            }

            override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {
                when (newState) {
                    PeerConnection.PeerConnectionState.CONNECTED -> setStatus("P2P 已连接", true)
                    PeerConnection.PeerConnectionState.DISCONNECTED,
                    PeerConnection.PeerConnectionState.FAILED,
                    PeerConnection.PeerConnectionState.CLOSED -> handleRemoteDisconnected("桌面断开")
                    else -> Unit
                }
            }

            override fun onDataChannel(dc: DataChannel) {
                // HOST 创建的通道，在这里接收
                dataChannel = dc
                wireChannel(dc)
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

    private fun wireChannel(dc: DataChannel) {
        dc.registerObserver(object : DataChannel.Observer {
            override fun onBufferedAmountChange(previousAmount: Long) {}
            override fun onStateChange() {
                val state = dc.state()
                val open = state == DataChannel.State.OPEN
                setStatus(
                    if (open) "P2P 已连接" else status,
                    open
                )
                if (open) sendHello()
                if (state == DataChannel.State.CLOSING || state == DataChannel.State.CLOSED) {
                    handleRemoteDisconnected("桌面断开")
                }
            }

            override fun onMessage(buffer: DataChannel.Buffer) {
                val bytes = ByteArray(buffer.data.remaining())
                buffer.data.get(bytes)
                val text = String(bytes, StandardCharsets.UTF_8)
                handleChannelMessage(text)
            }
        })
    }

    /** 连接建立后上报本机设备名，供桌面端区分多设备。 */
    private fun sendHello() {
        val json = JSONObject()
            .put("type", "hello")
            .put("device", deviceName())
        sendJson(json)
    }

    private fun deviceName(): String {
        val ctx = appContext
        val custom = ctx?.let {
            try {
                android.provider.Settings.Global.getString(it.contentResolver, "device_name")
            } catch (e: Exception) { null }
        }
        if (!custom.isNullOrBlank()) return custom
        val manufacturer = android.os.Build.MANUFACTURER?.replaceFirstChar { c -> c.uppercase() } ?: ""
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

    private fun handleChannelMessage(text: String) {
        val msg = try {
            JSONObject(text)
        } catch (e: Exception) {
            return
        }
        handlePeerMessage(msg)
    }

    private fun handlePeerMessage(msg: JSONObject) {
        when (msg.optString("type")) {
            "session" -> upsertSession(msg)
            "session-closed" -> removeSession(msg.optString("sessionId"))
        }
    }

    private fun upsertSession(msg: JSONObject) {
        val id = msg.getString("sessionId")
        val device = msg.optString("device")
        lastPairedRoomId?.let { if (device.isNotBlank()) updatePairingLabel(it, device) }
        val existing = sessions.firstOrNull { it.id == id }
        if (existing == null) {
            sessions.add(
                0,
                Session(id, msg.optString("app"), msg.optString("title"), device)
            )
        } else if (sessions.indexOf(existing) != 0) {
            // 桌面端重新聚焦该窗口，置顶以突出当前焦点
            sessions.remove(existing)
            sessions.add(0, existing)
        }
        // 桌面端焦点所在的会话即为当前激活会话
        activeSessionId = id
        notifySessions()
    }

    private fun removeSession(id: String) {
        if (id.isBlank()) return
        val removed = sessions.removeAll { it.id == id }
        if (!removed) return
        if (activeSessionId == id) {
            activeSessionId = sessions.firstOrNull()?.id
        }
        notifySessions()
    }

    private fun handleRemoteDisconnected(message: String) {
        signalingReady = false
        connectedState = false
        dataChannel = null
        pc = null
        clearSessions()
        setStatus(message, false)
    }

    private fun clearSessions() {
        val changed = sessions.isNotEmpty() || activeSessionId != null
        sessions.clear()
        activeSessionId = null
        if (changed) notifySessions()
    }

    /** 发送识别文本到桌面，并记入会话历史 */
    fun sendText(session: Session, text: String) {
        if (text.isBlank()) return
        val json = JSONObject()
            .put("type", "text")
            .put("text", text)
            .put("sessionId", session.id)
        sendJson(json)

        val m = ChatMessage(text, fromMe = true)
        session.messages.add(m)
        main.post { observers.forEach { it.onMessage(session.id, m) } }
    }

    /** 重新发送已有历史文本到桌面，但不新增历史记录。 */
    fun resendText(session: Session, text: String) {
        if (text.isBlank()) return
        val json = JSONObject()
            .put("type", "text")
            .put("text", text)
            .put("sessionId", session.id)
        sendJson(json)
    }

    /** 发送操作指令到桌面：enter / backspace / selectAll / clear。 */
    fun sendAction(session: Session, action: String) {
        if (!isConnected) return
        val json = JSONObject()
            .put("type", "action")
            .put("action", action)
            .put("sessionId", session.id)
        sendJson(json)
    }

    fun disconnect() {
        dataChannel?.close()
        pc?.close()
        signaling?.close()
        dataChannel = null
        pc = null
        signaling = null
        signalingReady = false
        connectedState = false
        transportMode = TransportMode.WEBRTC
        clearSessions()
        setStatus("未连接", false)
    }
}

/** 默认空实现的 SDP 观察者 */
open class SimpleSdpObserver : SdpObserver {
    override fun onCreateSuccess(p0: SessionDescription) {}
    override fun onSetSuccess() {}
    override fun onCreateFailure(p0: String?) {}
    override fun onSetFailure(p0: String?) {}
}

/** 默认空实现的 PeerConnection 观察者 */
open class SimplePcObserver : PeerConnection.Observer {
    override fun onSignalingChange(p0: PeerConnection.SignalingState?) {}
    override fun onIceConnectionChange(p0: PeerConnection.IceConnectionState?) {}
    override fun onIceConnectionReceivingChange(p0: Boolean) {}
    override fun onIceGatheringChange(p0: PeerConnection.IceGatheringState?) {}
    override fun onIceCandidate(p0: IceCandidate) {}
    override fun onIceCandidatesRemoved(p0: Array<out IceCandidate>?) {}
    override fun onAddStream(p0: org.webrtc.MediaStream?) {}
    override fun onRemoveStream(p0: org.webrtc.MediaStream?) {}
    override fun onDataChannel(p0: DataChannel) {}
    override fun onRenegotiationNeeded() {}
    override fun onConnectionChange(newState: PeerConnection.PeerConnectionState) {}
}
