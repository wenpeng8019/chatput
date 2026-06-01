package com.chatput.app

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

/**
 * WebSocket 信令客户端。
 * 协议与桌面端 / 信令服务器一致：
 *   发送: join-room {roomId, token}, signal {data}
 *   接收: peer-joined, signal, peer-left, error
 */
class SignalingClient(
    private val url: String,
    private val listener: Listener
) {
    interface Listener {
        fun onPeerJoined()
        fun onSignal(data: JSONObject)
        fun onPeerLeft()
        fun onError(reason: String)
        fun onClosed()
    }

    private val client = OkHttpClient()
    private var ws: WebSocket? = null

    fun connect(roomId: String, token: String) {
        val req = Request.Builder().url(url).build()
        ws = client.newWebSocket(req, object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: okhttp3.Response) {
                val join = JSONObject()
                    .put("type", "join-room")
                    .put("roomId", roomId)
                    .put("token", token)
                webSocket.send(join.toString())
            }

            override fun onMessage(webSocket: WebSocket, text: String) {
                val msg = JSONObject(text)
                when (msg.optString("type")) {
                    "peer-joined" -> listener.onPeerJoined()
                    "signal" -> listener.onSignal(msg.getJSONObject("data"))
                    "peer-left" -> listener.onPeerLeft()
                    "error" -> listener.onError(msg.optString("reason", "未知错误"))
                }
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                listener.onClosed()
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: okhttp3.Response?) {
                listener.onError(t.message ?: "信令连接失败")
            }
        })
    }

    /** 发送 signal 消息（包裹 SDP / ICE） */
    fun sendSignal(data: JSONObject) {
        val msg = JSONObject().put("type", "signal").put("data", data)
        ws?.send(msg.toString())
    }

    fun close() {
        ws?.close(1000, "bye")
        ws = null
    }
}
