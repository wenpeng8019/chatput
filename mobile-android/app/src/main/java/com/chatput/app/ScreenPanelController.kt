package com.chatput.app

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.PopupWindow
import android.widget.TextView
import org.webrtc.EglBase
import org.webrtc.RendererCommon
import org.webrtc.SurfaceViewRenderer
import org.webrtc.VideoTrack

/**
 * 远程窗口画面面板的可复用控制器。
 *
 * 把原 ScreenViewActivity 的全部逻辑（视口计算、主画面拖动、缩略图/元数据、
 * 视口节流下发、采集启停）抽离，供 ChatActivity 的「下拉幕布」面板内嵌使用。
 *
 * 生命周期：[bind] 绑定会话 → 幕布下拉时 [start] 开始采集 → 收起时 [stop] 停止 →
 * 页面销毁时 [release] 释放渲染器。start/stop 可反复调用。
 */
class ScreenPanelController(
    private val renderer: SurfaceViewRenderer,
    private val minimap: MinimapView,
    private val statusLabel: TextView,
    private val cover: View,
) : ScreenListener {

    companion object {
        private const val VIEWPORT_SEND_INTERVAL_MS = 33L // ~30/s
        private const val TAG = "chatput-screen"
    }

    private val main = Handler(Looper.getMainLooper())
    private var session: Session? = null
    private var connectionId: String = ""

    private var boundTrack: VideoTrack? = null
    private var started = false
    private var released = false
    private var layoutListener: android.view.ViewTreeObserver.OnPreDrawListener? = null

    // 视口（窗口像素系）。winW/winH 来自桌面 screen-meta。
    // vpX/vpY 用 Float 避免拖动时 Int 截断导致方向性速度偏差。
    private var winW = 0
    private var winH = 0
    private var winScale = 2f
    private var vpX = 0f
    private var vpY = 0f
    private var vpW = 0
    private var vpH = 0
    private var viewportInited = false
    private var displayScale = 1.0f  // 1.0=原始, 0.9/0.8/0.75=缩小
    private var lastMetaW = 0; private var lastMetaH = 0  // 用于检测桌面输出尺寸变化
    private val rendererLongPress = Runnable { showScaleMenu() }
    private var rendererLpPending = false
    private var longPressX = 0f; private var longPressY = 0f

    // 主画面拖动状态
    private var dragLastX = 0f
    private var dragLastY = 0f
    private var cachedDispScale = 0f

    private var lastViewportSentAt = 0L
    private val flushViewport = Runnable { sendViewportNow() }

    /** 初始化渲染器与交互。仅需调用一次。 */
    fun init(eglContext: EglBase.Context?) {
        renderer.init(eglContext, null)
        renderer.setScalingType(RendererCommon.ScalingType.SCALE_ASPECT_FIT)
        renderer.setEnableHardwareScaler(true)
        minimap.onViewportMove = { x, y -> moveViewportTo(x.toFloat(), y.toFloat()) }
        minimap.onLongPress = { showPositionPicker() }
        setupRendererDrag()
    }

    /** 绑定到某个会话（不开始采集）。 */
    fun bind(connectionId: String, session: Session?) {
        this.connectionId = connectionId
        this.session = session
    }

    val hasSession: Boolean get() = session != null

    /** 开始采集（幕布下拉到位时调用）。可重复调用。 */
    fun start() {
        if (started || released || session == null) return
        started = true
        viewportInited = false
        statusLabel.visibility = View.VISIBLE
        cover.visibility = View.VISIBLE
        ConnectionManager.setScreenListener(connectionId, this)
        renderer.post { startCaptureWhenReady() }
    }

    /** 停止采集（幕布收起时调用）。 */
    fun stop() {
        if (!started) return
        started = false
        viewportInited = false
        cover.visibility = View.VISIBLE
        main.removeCallbacks(flushViewport)
        ConnectionManager.setScreenListener(connectionId, null)
        session?.let { ConnectionManager.stopScreen(it) }
        boundTrack?.let { runCatching { it.removeSink(renderer) } }
        boundTrack = null
    }

    /** 释放渲染器（页面销毁时）。 */
    fun release() {
        if (released) return
        released = true
        layoutListener?.let { renderer.viewTreeObserver.removeOnPreDrawListener(it) }
        layoutListener = null
        stop()
        runCatching { renderer.release() }
    }

    private fun startCaptureWhenReady() {
        val s = session ?: return
        if (released || !started) return
        val rw = renderer.width
        val rh = renderer.height
        if (rw <= 0 || rh <= 0) {
            val listener = android.view.ViewTreeObserver.OnPreDrawListener {
                renderer.viewTreeObserver.removeOnPreDrawListener(layoutListener)
                startCaptureWhenReady()
                true
            }
            layoutListener = listener
            renderer.viewTreeObserver.addOnPreDrawListener(listener)
            return
        }
        layoutListener = null
        // 视口请求 = 渲染区物理像素 ÷ 手机密度，缩小首帧、加速首屏；
        // 真正视口在首个 meta 后重算下发。
        val density = renderer.resources.displayMetrics.density.coerceAtLeast(1f)
        ConnectionManager.startScreen(s, (rw / density).toInt().coerceAtLeast(2), (rh / density).toInt().coerceAtLeast(2))
    }

    override fun onVideoTrack(track: VideoTrack) {
        main.post {
            if (released) return@post
            boundTrack?.let { runCatching { it.removeSink(renderer) } }
            boundTrack = track
            runCatching { track.addSink(renderer) }
            statusLabel.visibility = View.GONE
            cover.visibility = View.GONE
        }
    }

    override fun onThumbnail(sessionId: String, jpeg: ByteArray) {
        if (sessionId != session?.id) return
        val bmp: Bitmap = BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size) ?: return
        main.post {
            if (!released) minimap.setThumbnail(bmp)
        }
    }

    override fun onScreenError(sessionId: String, message: String) {
        main.post {
            if (released) return@post
            stop()
            statusLabel.text = message
            statusLabel.visibility = View.VISIBLE
            cover.visibility = View.VISIBLE
        }
    }

    override fun onMeta(sessionId: String, winW: Int, winH: Int, scale: Float, x: Int, y: Int, w: Int, h: Int) {
        if (sessionId != session?.id) return
        val sizeChanged = viewportInited && (w != lastMetaW || h != lastMetaH) && w > 0 && h > 0
        lastMetaW = w; lastMetaH = h
        main.post {
            if (released) return@post
            if (sizeChanged) {
                Log.d(TAG, "meta: size changed -> hold renderer 120ms")
                boundTrack?.removeSink(renderer)
                main.postDelayed({
                    if (!released && started) {
                        boundTrack?.addSink(renderer)
                        Log.d(TAG, "meta: renderer resumed")
                    }
                }, 120)
            }
            this.winW = winW
            this.winH = winH
            winScale = if (scale > 0f) scale else 2f
            if (!viewportInited && winW > 0 && winH > 0) {
                viewportInited = true
                computeAndSendInitialViewport()
            }
            minimap.setMeta(winW, winH, vpX.toInt(), vpY.toInt(), vpW, vpH)
        }
    }

    /**
     * 视口尺寸（窗口像素）= 手机渲染区物理像素 ÷ 手机显示密度。
     * 手机 retina（density≈2），请求较小子区域再上采样填满 → 清晰 1:1、帧更小、延迟更低。
     */
    private fun computeAndSendInitialViewport() {
        val rw = renderer.width
        val rh = renderer.height
        if (rw <= 0 || rh <= 0 || winW <= 0 || winH <= 0) return
        val density = renderer.resources.displayMetrics.density.coerceAtLeast(1f)
        val rawW = (rw / density / displayScale).toInt().coerceAtLeast(1)
        val rawH = (rh / density / displayScale).toInt().coerceAtLeast(1)
        val fit = minOf(winW.toFloat() / rawW, winH.toFloat() / rawH, 1.0f)
        vpW = (rawW * fit).toInt().coerceIn(1, winW)
        vpH = (rawH * fit).toInt().coerceIn(1, winH)
        vpX = (winW - vpW).coerceAtLeast(0).toFloat()
        vpY = (winH - vpH).coerceAtLeast(0).toFloat()
        Log.d(TAG, "initVp renderer=${rw}x${rh} density=$density -> vp=($vpX,$vpY ${vpW}x$vpH) win=${winW}x${winH}")
        sendViewportNow()
    }

    /** 把视口左上角移到窗口像素 (x,y)，钳制后节流下发。 */
    private fun moveViewportTo(x: Float, y: Float) {
        if (winW <= 0 || winH <= 0 || vpW <= 0 || vpH <= 0) return
        vpX = x.coerceIn(0f, (winW - vpW).toFloat().coerceAtLeast(0f))
        vpY = y.coerceIn(0f, (winH - vpH).toFloat().coerceAtLeast(0f))
        minimap.setMeta(winW, winH, vpX.toInt(), vpY.toInt(), vpW, vpH)
        queueViewport()
    }

    /**
     * 主画面触控 → 桌面鼠标事件：
     * - 单击（无拖动）→ pointer-down + pointer-up
     * - 单指拖动 → 移动视口（原有行为）
     * - 双指拖动 → 滚轮 scroll
     */
    private fun setupRendererDrag() {
        val tapSlop = ViewConfiguration.get(renderer.context).scaledTouchSlop.toFloat()
        var isTap = false
        var tapX = 0f
        var tapY = 0f
        var scrollBaseY = 0f
        var scrolling = false

        renderer.setOnTouchListener { _, event ->
            when (event.actionMasked and MotionEvent.ACTION_MASK) {
                MotionEvent.ACTION_DOWN -> {
                    dragLastX = event.x; dragLastY = event.y
                    isTap = true; tapX = event.x; tapY = event.y
                    longPressX = event.x; longPressY = event.y
                    scrolling = false
                    cachedDispScale = contentDispScale()
                    rendererLpPending = true
                    main.postDelayed(rendererLongPress, 600)
                    true
                }
                MotionEvent.ACTION_POINTER_DOWN -> {
                    if (event.pointerCount >= 2) {
                        scrolling = true; isTap = false
                        scrollBaseY = (event.getY(0) + event.getY(1)) / 2f
                    }
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (rendererLpPending && (kotlin.math.abs(event.x - tapX) > tapSlop || kotlin.math.abs(event.y - tapY) > tapSlop)) {
                        main.removeCallbacks(rendererLongPress); rendererLpPending = false
                    }
                    if (scrolling && event.pointerCount >= 2) {
                        val avgY = (event.getY(0) + event.getY(1)) / 2f
                        val dy = scrollBaseY - avgY
                        scrollBaseY = avgY
                        if (kotlin.math.abs(dy) > 1f) {
                            val scrollDy = if (cachedDispScale > 0f) (dy / cachedDispScale).toInt() else 0
                            if (scrollDy != 0) {
                                session?.let { ConnectionManager.sendPointerScroll(it, 0, scrollDy) }
                            }
                        }
                    } else if (!scrolling) {
                        if (kotlin.math.abs(event.x - tapX) > tapSlop ||
                            kotlin.math.abs(event.y - tapY) > tapSlop) {
                            isTap = false
                        }
                        if (vpW > 0 && vpH > 0 && renderer.width > 0 && renderer.height > 0) {
                            if (cachedDispScale > 0f) {
                                val dxWin = (event.x - dragLastX) / cachedDispScale
                                val dyWin = (event.y - dragLastY) / cachedDispScale
                                dragLastX = event.x; dragLastY = event.y
                                moveViewportTo(vpX - dxWin, vpY - dyWin)
                            }
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP -> {
                    if (rendererLpPending) { main.removeCallbacks(rendererLongPress); rendererLpPending = false }
                    if (isTap) {
                        val s = session ?: return@setOnTouchListener true
                        val (wx, wy) = rendererToWindow(tapX, tapY)
                        ConnectionManager.sendPointerDown(s, wx, wy)
                        ConnectionManager.sendPointerUp(s, wx, wy)
                    }
                    isTap = false; scrolling = false
                    true
                }
                MotionEvent.ACTION_POINTER_UP -> { scrolling = false; true }
                MotionEvent.ACTION_CANCEL -> { isTap = false; scrolling = false; main.removeCallbacks(rendererLongPress); rendererLpPending = false; true }
                else -> true
            }
        }
    }

    /** 渲染器视图坐标 → 窗口绝对逻辑坐标。 */
    private fun rendererToWindow(rx: Float, ry: Float): Pair<Int, Int> {
        if (vpW <= 0 || vpH <= 0 || renderer.width == 0 || renderer.height == 0) return Pair(0, 0)
        val dispScale = contentDispScale()
        val contentLeft = (renderer.width - vpW * dispScale) / 2f
        val contentTop = (renderer.height - vpH * dispScale) / 2f
        val wx = ((rx - contentLeft) / dispScale).toInt().coerceIn(0, vpW - 1)
        val wy = ((ry - contentTop) / dispScale).toInt().coerceIn(0, vpH - 1)
        return Pair((vpX + wx).toInt(), (vpY + wy).toInt())
    }

    /** SCALE_ASPECT_FIT 渲染的显示缩放系数。 */
    private fun contentDispScale(): Float {
        if (vpW <= 0 || vpH <= 0 || renderer.width == 0 || renderer.height == 0) return 0f
        return minOf(renderer.width.toFloat() / vpW, renderer.height.toFloat() / vpH)
    }

    private fun queueViewport() {
        val now = System.currentTimeMillis()
        val elapsed = now - lastViewportSentAt
        if (elapsed >= VIEWPORT_SEND_INTERVAL_MS) {
            sendViewportNow()
        } else {
            main.removeCallbacks(flushViewport)
            main.postDelayed(flushViewport, VIEWPORT_SEND_INTERVAL_MS - elapsed)
        }
    }

    private fun sendViewportNow() {
        val s = session ?: return
        if (vpW <= 0 || vpH <= 0) return
        lastViewportSentAt = System.currentTimeMillis()
        Log.d(TAG, "send vp=(${vpX.toInt()},${vpY.toInt()} ${vpW}x$vpH)")
        ConnectionManager.sendViewport(s, vpX.toInt(), vpY.toInt(), vpW, vpH)
    }

    // 缩略图位置

    private fun showPositionPicker() {
        minimap.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
        val ctx = minimap.context
        val content = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(8.dp, 8.dp, 8.dp, 8.dp)
        }
        val popup = PopupWindow(content,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT, true)
        popup.isOutsideTouchable = true
        popup.setBackgroundDrawable(ColorDrawable(Color.parseColor("#CC1C1C1E")))

        MinimapPosition.values().forEach { pos ->
            val label = TextView(ctx).apply {
                text = pos.label
                textSize = 14f
                setTextColor(Color.WHITE)
                setPadding(16.dp, 10.dp, 16.dp, 10.dp)
            }
            label.setOnClickListener {
                popup.dismiss()
                applyMinimapPosition(pos)
            }
            content.addView(label)
        }
        content.measure(
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        popup.showAsDropDown(minimap, -content.measuredWidth + minimap.width, -content.measuredHeight - 8.dp)
    }

    private fun applyMinimapPosition(pos: MinimapPosition) {
        (minimap.layoutParams as? FrameLayout.LayoutParams)?.let { lp ->
            lp.gravity = pos.gravity
            minimap.layoutParams = lp
        }
    }

    // 显示缩放菜单

    private fun showScaleMenu() {
        renderer.performHapticFeedback(android.view.HapticFeedbackConstants.LONG_PRESS)
        val ctx = renderer.context
        val content = LinearLayout(ctx).apply {
            orientation = LinearLayout.VERTICAL; setPadding(8.dp, 8.dp, 8.dp, 8.dp)
        }
        val popup = PopupWindow(content, ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, true)
        popup.isOutsideTouchable = true
        popup.setBackgroundDrawable(ColorDrawable(Color.parseColor("#CC1C1C1E")))

        floatArrayOf(1.0f, 0.9f, 0.8f, 0.75f).forEach { s ->
            val label = TextView(ctx).apply {
                text = if (s == 1.0f) "1:1" else "%.2f".format(s)
                textSize = 14f; setTextColor(Color.WHITE); setPadding(16.dp, 10.dp, 16.dp, 10.dp)
                if (s == displayScale) setTextColor(Color.parseColor("#FF007AFF"))
            }
            label.setOnClickListener { popup.dismiss(); applyScale(s) }
            content.addView(label)
        }
        content.measure(View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        // showAsDropDown y-offset 从 renderer 底部算起，减掉 renderer 高度转成从顶部算
        val px = longPressX.toInt().coerceAtMost(renderer.width - content.measuredWidth - 16.dp)
        val py = longPressY.toInt() - renderer.height - content.measuredHeight - 16.dp
        popup.showAsDropDown(renderer, px, py)
    }

    private fun applyScale(scale: Float) {
        val oldScale = displayScale
        displayScale = scale
        val rw = renderer.width; val rh = renderer.height
        if (rw <= 0 || rh <= 0 || winW <= 0 || winH <= 0) return
        val density = renderer.resources.displayMetrics.density.coerceAtLeast(1f)
        val rawW = (rw / density / scale).toInt().coerceAtLeast(1)
        val rawH = (rh / density / scale).toInt().coerceAtLeast(1)
        val fit = minOf(winW.toFloat() / rawW, winH.toFloat() / rawH, 1.0f)
        val newW = (rawW * fit).toInt().coerceIn(1, winW)
        val newH = (rawH * fit).toInt().coerceIn(1, winH)
        val newX = (winW - newW).coerceAtLeast(0)
        val newY = (winH - newH).coerceAtLeast(0)
        val cx = vpX + vpW / 2f; val cy = vpY + vpH / 2f  // 旧视口中心
        vpW = newW; vpH = newH
        vpX = (cx - newW / 2f).coerceIn(0f, (winW - newW).coerceAtLeast(0).toFloat())
        vpY = (cy - newH / 2f).coerceIn(0f, (winH - newH).coerceAtLeast(0).toFloat())
        Log.d(TAG, "scale $oldScale->$scale vp=(${vpX.toInt()},${vpY.toInt()} ${vpW}x$vpH)")
        minimap.setMeta(winW, winH, vpX.toInt(), vpY.toInt(), vpW, vpH)
        sendViewportNow()
    }

    private val Int.dp: Int get() = (this * renderer.resources.displayMetrics.density).toInt()
}

enum class MinimapPosition(val gravity: Int, val label: String) {
    TOP_LEFT(Gravity.TOP or Gravity.START, "左上"),
    TOP_RIGHT(Gravity.TOP or Gravity.END, "右上"),
    LEFT(Gravity.CENTER_VERTICAL or Gravity.START, "左侧中"),
    RIGHT(Gravity.CENTER_VERTICAL or Gravity.END, "右侧中"),
    BOTTOM_LEFT(Gravity.BOTTOM or Gravity.START, "左下"),
    BOTTOM_RIGHT(Gravity.BOTTOM or Gravity.END, "右下"),
}
