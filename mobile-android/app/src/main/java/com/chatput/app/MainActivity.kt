package com.chatput.app

import android.Manifest
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.transition.ChangeBounds
import android.transition.Fade
import android.transition.TransitionManager
import android.transition.TransitionSet
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.view.animation.DecelerateInterpolator
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updateLayoutParams
import androidx.core.view.updatePadding
import androidx.core.widget.TextViewCompat
import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.LinearLayoutManager
import com.journeyapps.barcodescanner.ScanContract
import com.journeyapps.barcodescanner.ScanOptions
import com.chatput.app.databinding.ActivityMainBinding
import kotlin.math.min

/** 会话列表 + 扫码配对入口 */
class MainActivity : AppCompatActivity(), ConnectionManager.Observer {

    private lateinit var binding: ActivityMainBinding
    private lateinit var adapter: SessionAdapter
    private var headerCompact: Boolean? = null
    private var headerScrollOffset = 0
    private var systemBottomInset = 0

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
        WindowCompat.setDecorFitsSystemWindows(window, false)
        applySystemBarAppearance()
        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)
        applyEdgeToEdgeInsets()

        adapter = SessionAdapter(ConnectionManager.sessions) { session ->
            startActivity(
                Intent(this, ChatActivity::class.java)
                    .putExtra(ChatActivity.EXTRA_SESSION_ID, session.id)
            )
        }
        binding.list.layoutManager = LinearLayoutManager(this)
        binding.list.adapter = adapter
        bindHeaderScrollBehavior()
        binding.headerCard.bringToFront()
        binding.headerCard.addOnLayoutChangeListener { _, _, _, _, _, _, _, _, _ ->
            updateListTopPadding()
            updateHeaderScrollOffset()
        }

        binding.fabScan.setOnClickListener { ensurePermsThenScan() }
        binding.status.setOnClickListener {
            if (ConnectionManager.isConnected) showConnectionMenu()
        }

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
        val showSessionShell = ConnectionManager.hasConnectionContext
        adapter.notifyDataSetChanged()
        binding.empty.visibility =
            if (ConnectionManager.sessions.isEmpty()) View.VISIBLE else View.GONE
        binding.empty.text = if (showSessionShell) {
            "已连接，请先在桌面选择要输入的窗口"
        } else {
            "扫码连接你的桌面"
        }
        renderRecentDevices()
        renderStatus(ConnectionManager.status, ConnectionManager.isConnected)
        renderHeaderMode(showSessionShell)
        binding.root.post { updateHeaderScrollOffset() }
    }

    /** 未连接时展示最近 3 个历史设备，点击免扫码直接尝试重连。 */
    private fun renderRecentDevices() {
        val container = binding.recentContainer
        // 保留第一个子 View（"历史连接"标签），仅清理动态设备条目
        if (container.childCount > 1) {
            container.removeViews(1, container.childCount - 1)
        }
        val recents = if (ConnectionManager.hasConnectionContext) emptyList()
        else ConnectionManager.recentPairings(this)
        if (recents.isEmpty()) {
            container.visibility = View.GONE
            return
        }
        container.visibility = View.VISIBLE
        recents.forEach { pairing ->
            val item = layoutInflater.inflate(R.layout.item_recent_device, container, false)
            item.findViewById<android.widget.TextView>(R.id.device_label).text = pairing.label
            item.findViewById<ImageView>(R.id.device_delete).setOnClickListener {
                ConnectionManager.removeRecentPairing(this, pairing.payload)
                renderRecentDevices()
            }
            item.setOnClickListener {
                pair(pairing.payload)
            }
            container.addView(item)
        }
    }

    // --- ConnectionManager.Observer ---
    override fun onStatus(status: String, connected: Boolean) {
        refresh()
    }

    override fun onSessionsChanged() {
        refresh()
    }

    override fun onMessage(sessionId: String, msg: ChatMessage) {}

    private fun applyEdgeToEdgeInsets() {
        val headerTop = 20.dp
        val listBottom = 110.dp
        val fabBottom = 30.dp

        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            systemBottomInset = systemBars.bottom

            binding.headerCard.updateLayoutParams<ViewGroup.MarginLayoutParams> {
                topMargin = headerTop + systemBars.top
            }
            binding.list.updatePadding(
                bottom = listBottom + systemBars.bottom
            )
            binding.fabScan.updateLayoutParams<ViewGroup.MarginLayoutParams> {
                bottomMargin = fabBottom + systemBars.bottom
            }
            binding.root.post {
                updateListTopPadding()
                updateHeaderScrollOffset()
            }

            insets
        }
    }

    private fun applySystemBarAppearance() {
        val nightMode = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        val lightBars = nightMode != Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, window.decorView)?.let { controller ->
            controller.isAppearanceLightStatusBars = lightBars
            controller.isAppearanceLightNavigationBars = lightBars
        }
    }

    private fun renderStatus(status: String, connected: Boolean) {
        val showSessionShell = ConnectionManager.hasConnectionContext
        val shouldAnimate = headerCompact != null && headerCompact != showSessionShell
        if (shouldAnimate) beginHeaderTransition()

        binding.status.text = status
        val background = if (connected) {
            R.drawable.bg_status_chip_connected
        } else {
            R.drawable.bg_status_chip_idle
        }
        val textColor = if (connected) {
            R.color.chatput_status_connected_text
        } else {
            R.color.chatput_status_idle_text
        }
        binding.status.setBackgroundResource(background)
        binding.status.setTextColor(ContextCompat.getColor(this, textColor))
        binding.status.isClickable = connected
        binding.status.isFocusable = connected
        TextViewCompat.setCompoundDrawableTintList(binding.status, null)
        renderHeaderMode(showSessionShell)
    }

    private fun showConnectionMenu() {
        val content = layoutInflater.inflate(R.layout.popup_connection_actions, binding.root, false)
        val container = content.findViewById<LinearLayout>(R.id.connection_menu_content)
        content.findViewById<TextView>(R.id.connection_group_label).text = ConnectionManager.connectionGroupLabel()
        var popup: PopupWindow? = null

        ConnectionManager.connectedDeviceNames().forEach { device ->
            val row = layoutInflater.inflate(R.layout.item_connection_close, container, false)
            row.findViewById<TextView>(R.id.connection_close_label).text = "关闭 $device"
            row.setOnClickListener {
                popup?.dismiss()
                ConnectionManager.disconnect()
                refresh()
                Toast.makeText(this, "已断开 $device", Toast.LENGTH_SHORT).show()
            }
            container.addView(row)
        }

        popup = PopupWindow(
            content,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            true
        )
        popup.isOutsideTouchable = true
        popup.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        content.measure(
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        )
        val xOffset = binding.status.width - content.measuredWidth + 14.dp
        val yOffset = 8.dp
        popup.showAsDropDown(binding.status, xOffset, yOffset)
    }

    private fun beginHeaderTransition() {
        val transition = TransitionSet()
            .setOrdering(TransitionSet.ORDERING_TOGETHER)
            .addTransition(ChangeBounds())
            .addTransition(Fade(Fade.IN or Fade.OUT))
            .setDuration(260)
            .setInterpolator(DecelerateInterpolator())
        TransitionManager.beginDelayedTransition(binding.root, transition)
    }

    private fun renderHeaderMode(connected: Boolean) {
        headerCompact = connected

        binding.headerTitle.visibility = if (connected) View.GONE else View.VISIBLE
        binding.headerDescription.visibility = if (connected) View.GONE else View.VISIBLE

        binding.headerContent.orientation = if (connected) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
        binding.headerContent.gravity = if (connected) android.view.Gravity.CENTER_VERTICAL else android.view.Gravity.NO_GRAVITY
        binding.headerContent.setPadding(
            if (connected) 16.dp else 16.dp,
            if (connected) 14.dp else 18.dp,
            if (connected) 18.dp else 18.dp,
            if (connected) 14.dp else 18.dp
        )

        binding.appLabel.textSize = if (connected) 17f else 12f
        binding.appLabel.updateLayoutParams<LinearLayout.LayoutParams> {
            width = if (connected) 0 else LinearLayout.LayoutParams.WRAP_CONTENT
            weight = if (connected) 1f else 0f
        }
        binding.status.updateLayoutParams<LinearLayout.LayoutParams> {
            topMargin = if (connected) 0 else 16.dp
        }
        binding.root.post { updateHeaderScrollOffset() }
    }

    private fun bindHeaderScrollBehavior() {
        binding.list.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                updateHeaderScrollOffset()
            }
        })
    }

    private fun updateHeaderScrollOffset() {
        val listCanScroll = binding.list.computeVerticalScrollRange() > binding.list.computeVerticalScrollExtent()
        val shouldCollapse = headerCompact == true && listCanScroll
        val headerTop = (binding.headerCard.layoutParams as ViewGroup.MarginLayoutParams).topMargin
        val maxOffset = if (shouldCollapse) binding.headerCard.height + headerTop else 0
        val offset = min(binding.list.computeVerticalScrollOffset(), maxOffset)
        if (offset == headerScrollOffset) return

        headerScrollOffset = offset
        binding.headerCard.translationY = -offset.toFloat()
    }

    private fun updateListTopPadding() {
        val listTop = binding.headerCard.bottom + 14.dp
        val listBottom = 110.dp + systemBottomInset
        if (binding.list.paddingTop == listTop && binding.list.paddingBottom == listBottom) return
        binding.list.updatePadding(top = listTop, bottom = listBottom)
    }

    private val Int.dp: Int
        get() = (this * resources.displayMetrics.density).toInt()
}
