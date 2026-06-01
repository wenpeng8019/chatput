package com.remoteinput.app

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

    interface Observer {
        fun onStatus(status: String, connected: Boolean)
        fun onSessionsChanged()
        fun onMessage(sessionId: String, msg: ChatMessage)
    }

    private val main = Handler(Looper.getMainLooper())
    private val observers = mutableSetOf<Observer>()

    val sessions = mutableListOf<Session>()
    var status: String = "未连接"
        private set
    val isConnected: Boolean
        get() = dataChannel?.state() == DataChannel.State.OPEN

    private var factory: PeerConnectionFactory? = null
    private var pc: PeerConnection? = null
    private var dataChannel: DataChannel? = null
    private var signaling: SignalingClient? = null
    private var appContext: Context? = null

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
        main.post { observers.forEach { it.onStatus(s, connected) } }
    }

    private fun notifySessions() {
        main.post { observers.forEach { it.onSessionsChanged() } }
    }

    fun sessionById(id: String): Session? = sessions.firstOrNull { it.id == id }

    /**
     * 用扫码得到的 JSON 配对： {"url":"ws://...:8080","roomId":"...","token":"..."}
     */
    fun pairWith(context: Context, qrPayload: String) {
        appContext = context.applicationContext
        ensureFactory()

        val data = JSONObject(qrPayload)
        val url = data.getString("url")
        val roomId = data.getString("roomId")
        val token = data.getString("token")

        setStatus("连接信令服务器…", false)
        signaling = SignalingClient(url, this)
        signaling!!.connect(roomId, token)
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
        setStatus("配对成功，正在建立连接…", false)
        createPeerConnection()
    }

    override fun onSignal(data: JSONObject) {
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

    override fun onPeerLeft() {
        setStatus("桌面端已断开", false)
    }

    override fun onError(reason: String) {
        setStatus("错误: $reason", false)
    }

    override fun onClosed() {
        setStatus("信令断开", false)
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
                if (newState == PeerConnection.PeerConnectionState.CONNECTED) {
                    setStatus("P2P 已连接", true)
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
                setStatus(
                    if (dc.state() == DataChannel.State.OPEN) "P2P 已连接" else status,
                    dc.state() == DataChannel.State.OPEN
                )
            }

            override fun onMessage(buffer: DataChannel.Buffer) {
                val bytes = ByteArray(buffer.data.remaining())
                buffer.data.get(bytes)
                val text = String(bytes, StandardCharsets.UTF_8)
                handleChannelMessage(text)
            }
        })
    }

    private fun handleChannelMessage(text: String) {
        val msg = try {
            JSONObject(text)
        } catch (e: Exception) {
            return
        }
        if (msg.optString("type") == "session") {
            upsertSession(msg)
        }
    }

    private fun upsertSession(msg: JSONObject) {
        val id = msg.getString("sessionId")
        if (sessions.none { it.id == id }) {
            sessions.add(
                0,
                Session(id, msg.optString("app"), msg.optString("title"))
            )
        }
        notifySessions()
    }

    /** 发送识别文本到桌面，并记入会话历史 */
    fun sendText(session: Session, text: String) {
        if (text.isBlank()) return
        val json = JSONObject()
            .put("type", "text")
            .put("text", text)
            .put("sessionId", session.id)
        val buffer = ByteBuffer.wrap(json.toString().toByteArray(StandardCharsets.UTF_8))
        dataChannel?.send(DataChannel.Buffer(buffer, false))

        val m = ChatMessage(text, fromMe = true)
        session.messages.add(m)
        main.post { observers.forEach { it.onMessage(session.id, m) } }
    }

    fun disconnect() {
        dataChannel?.close()
        pc?.close()
        signaling?.close()
        dataChannel = null
        pc = null
        signaling = null
        sessions.clear()
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
