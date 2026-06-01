package com.chatput.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.View
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.LinearLayoutManager
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.chatput.app.databinding.ActivityMainBinding

/** 会话列表 + 扫码配对入口 */
class MainActivity : AppCompatActivity(), ConnectionManager.Observer {

    private lateinit var binding: ActivityMainBinding
    private lateinit var adapter: SessionAdapter

    private val scanLauncher = registerForActivityResult(ScanContract()) { result ->
        val contents = result.contents
        if (contents != null) {
            pair(contents)
        }
    }

    private val permLauncher = registerForActivityResult(
        ActivityResultContracts.RequestMultiplePermissions()
    ) { /* 结果在使用处再判断 */ }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        adapter = SessionAdapter(ConnectionManager.sessions) { session ->
            startActivity(
                Intent(this, ChatActivity::class.java)
                    .putExtra(ChatActivity.EXTRA_SESSION_ID, session.id)
            )
        }
        binding.list.layoutManager = LinearLayoutManager(this)
        binding.list.adapter = adapter

        binding.fabScan.setOnClickListener { ensurePermsThenScan() }

        requestRuntimePerms()

        // 后台预加载离线识别模型（首次加载较慢）
        SpeechHelper.preload(this)
    }

    override fun onResume() {
        super.onResume()
        ConnectionManager.addObserver(this)
        refresh()
    }

    override fun onPause() {
        super.onPause()
        ConnectionManager.removeObserver(this)
    }

    private fun requestRuntimePerms() {
        permLauncher.launch(arrayOf(Manifest.permission.RECORD_AUDIO, Manifest.permission.CAMERA))
    }

    private fun ensurePermsThenScan() {
        val cam = ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA)
        if (cam != PackageManager.PERMISSION_GRANTED) {
            ActivityCompat.requestPermissions(this, arrayOf(Manifest.permission.CAMERA), 1)
            return
        }
        val options = ScanOptions().apply {
            setPrompt("扫描桌面端二维码配对")
            setBeepEnabled(false)
            setOrientationLocked(true)
            captureActivity = PortraitCaptureActivity::class.java
        }
        scanLauncher.launch(options)
    }

    private fun pair(qrPayload: String) {
        try {
            ConnectionManager.pairWith(this, qrPayload)
            Toast.makeText(this, "配对中…", Toast.LENGTH_SHORT).show()
        } catch (e: Exception) {
            Toast.makeText(this, "二维码无效", Toast.LENGTH_SHORT).show()
        }
    }

    private fun refresh() {
        adapter.notifyDataSetChanged()
        binding.empty.visibility =
            if (ConnectionManager.sessions.isEmpty()) View.VISIBLE else View.GONE
        binding.status.text = ConnectionManager.status
    }

    // --- ConnectionManager.Observer ---
    override fun onStatus(status: String, connected: Boolean) {
        binding.status.text = status
    }

    override fun onSessionsChanged() {
        refresh()
    }

    override fun onMessage(sessionId: String, msg: ChatMessage) {}
}
