package com.chatput.app

/** 一个会话 = 桌面端的一个输入窗口 */
data class Session(
    val id: String,
    val app: String,
    val title: String,
    val device: String = "",
    val messages: MutableList<ChatMessage> = mutableListOf()
)

/** 一条消息 */
data class ChatMessage(
    val text: String,
    val fromMe: Boolean,
    val ts: Long = System.currentTimeMillis()
)
