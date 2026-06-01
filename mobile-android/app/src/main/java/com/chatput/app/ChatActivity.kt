package com.chatput.app

import android.Manifest
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.MotionEvent
import android.view.View
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.LinearLayoutManager
import com.chatput.app.databinding.ActivityChatBinding

/** 聊天界面：按住按钮说话，松开发送识别文本到桌面 */
class ChatActivity : AppCompatActivity(), ConnectionManager.Observer {

    companion object {
        const val EXTRA_SESSION_ID = "session_id"
    }

    private lateinit var binding: ActivityChatBinding
    private lateinit var adapter: MessageAdapter
    private lateinit var speech: SpeechHelper
    private var session: Session? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityChatBinding.inflate(layoutInflater)
        setContentView(binding.root)

        val id = intent.getStringExtra(EXTRA_SESSION_ID)
        session = ConnectionManager.sessionById(id ?: "")
        if (session == null) {
            finish()
            return
        }

        title = session!!.app.ifBlank { "聊入" }
        binding.subtitle.text = session!!.title

        adapter = MessageAdapter(session!!.messages)
        binding.list.layoutManager = LinearLayoutManager(this).apply { stackFromEnd = true }
        binding.list.adapter = adapter
        scrollToBottom()

        speech = SpeechHelper(this)

        binding.btnTalk.setOnTouchListener { v, event ->
            when (event.action) {
                MotionEvent.ACTION_DOWN -> {
                    startTalking(v)
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    stopTalking(v)
                    true
                }
                else -> false
            }
        }

        binding.btnEnter.setOnClickListener { sendAction("enter") }
        binding.btnBackspace.setOnClickListener { sendAction("backspace") }
        binding.btnSelectAll.setOnClickListener { sendAction("selectAll") }
        binding.btnClear.setOnClickListener { sendAction("clear") }
    }

    private fun sendAction(action: String) {
        if (!ConnectionManager.isConnected) {
            Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            return
        }
        session?.let { ConnectionManager.sendAction(it, action) }
    }

    override fun onResume() {
        super.onResume()
        ConnectionManager.addObserver(this)
    }

    override fun onPause() {
        super.onPause()
        ConnectionManager.removeObserver(this)
    }

    override fun onDestroy() {
        super.onDestroy()
        speech.destroy()
    }

    private fun startTalking(v: View) {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Toast.makeText(this, "请先授予录音权限", Toast.LENGTH_SHORT).show()
            return
        }
        if (!ConnectionManager.isConnected) {
            Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            return
        }
        v.isPressed = true
        binding.hint.text = "正在听…"
        speech.start(object : SpeechHelper.Callback {
            override fun onPartial(text: String) {
                binding.hint.text = text
            }

            override fun onResult(text: String) {
                binding.hint.text = "按住说话"
                if (text.isNotBlank()) {
                    session?.let {
                        ConnectionManager.sendText(it, text)
                    }
                }
            }

            override fun onError(message: String) {
                binding.hint.text = "按住说话"
                Toast.makeText(this@ChatActivity, message, Toast.LENGTH_SHORT).show()
            }
        })
    }

    private fun stopTalking(v: View) {
        v.isPressed = false
        speech.stop()
    }

    private fun scrollToBottom() {
        if (adapter.itemCount > 0) binding.list.scrollToPosition(adapter.itemCount - 1)
    }

    // --- ConnectionManager.Observer ---
    override fun onStatus(status: String, connected: Boolean) {}

    override fun onSessionsChanged() {}

    override fun onMessage(sessionId: String, msg: ChatMessage) {
        if (sessionId == session?.id) {
            adapter.notifyItemInserted(adapter.itemCount - 1)
            scrollToBottom()
        }
    }
}
