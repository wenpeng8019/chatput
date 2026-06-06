package com.chatput.app

import android.animation.ValueAnimator
import android.view.MotionEvent
import android.view.VelocityTracker
import android.view.View
import android.view.ViewConfiguration
import android.view.animation.DecelerateInterpolator
import kotlin.math.abs

/**
 * 远程窗口画面「下拉幕布」控制器。
 *
 * 把视频面板做成一块从屏幕顶部下拉、像幕布一样覆盖标题与消息列表的悬浮面板：
 * - 标题区下滑手势把幕布拉下；幕布顶部的握把上滑把它收起。
 * - 幕布完全收起时停止采集；下拉打开时开始采集（[ScreenPanelController]）。
 * - 幕布下边缘有投影（[shadow]）跟随移动，营造悬浮立体面板。
 * - 幕布顶部延展到状态栏下（沉浸式）：面板本身不施加 top inset。
 *
 * 面板通过 translationY 在 [-panelHeight, 0] 间滑动：0=完全打开，-panelHeight=完全收起。
 * 弹出文字键盘时，整块面板再额外上移 keyboardLift（[setKeyboardLift]）让出输入框空间，
 * 画面尺寸不变（窗帘式上推，而非压缩重缩放）。
 */
class ScreenCurtainController(
    private val panel: View,
    private val shadow: View,
    private val grabHandle: View,
    private val headerDragHost: View,
    private val controller: ScreenPanelController,
) {
    private val touchSlop = ViewConfiguration.get(panel.context).scaledTouchSlop
    private var panelHeight = 0f
    val opened: Boolean get() = internalOpened
    private var internalOpened = false
    private var animator: ValueAnimator? = null
    private var keyboardLift = 0f
    private val collapseZones = mutableListOf<View>()

    init {
        panel.post { measureAndHide() }
        bindHeaderGesture()
        bindGrabGesture()
    }

    private fun measureAndHide() {
        panelHeight = panel.height.toFloat().coerceAtLeast(1f)
        if (!opened) {
            panel.translationY = -panelHeight
            // 收起时用 GONE 而非 INVISIBLE：SurfaceView 的 surface 是独立合成层，
            // 不受 translationY/INVISIBLE 可靠约束，会在布局位置（屏幕顶部）泄露出透明/黑边。
            // GONE 会把面板移出布局，其下的 SurfaceView 拿不到 surface，彻底消除泄露。
            panel.visibility = View.GONE
            shadow.visibility = View.GONE
        }
        syncShadow()
    }

    /** 幕布底边随面板移动。投影与收起热区都需跟随面板的 translationY。 */
    private fun syncShadow() {
        shadow.translationY = panel.translationY
        collapseZones.forEach { it.translationY = panel.translationY }
    }

    private fun progress(): Float {
        if (panelHeight <= 0f) return if (opened) 1f else 0f
        return ((panel.translationY + panelHeight) / panelHeight).coerceIn(0f, 1f)
    }

    // ---- 标题区下滑：把幕布拉下 ----

    private var headerDownY = 0f
    private var headerTracking = false

    private fun bindHeaderGesture() {
        headerDragHost.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    headerDownY = event.rawY
                    headerTracking = false
                    // 标题文字区无可点击内容（菜单按钮作为子 View 会先行消费自身触摸），
                    // 这里消费 DOWN 以保证后续 MOVE/UP 能持续投递，从而识别下滑手势。
                    !opened
                }
                MotionEvent.ACTION_MOVE -> {
                    val dy = event.rawY - headerDownY
                    if (!headerTracking && dy > touchSlop && !opened) {
                        headerTracking = true
                        ensureVisible()
                        cancelAnim()
                    }
                    if (headerTracking) {
                        setTranslation(-panelHeight + dy.coerceIn(0f, panelHeight))
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (headerTracking) {
                        headerTracking = false
                        settle()
                    }
                    true
                }
                else -> false
            }
        }
    }

    // ---- 幕布顶部握把：上滑收起 / 继续下拉 ----

    private var grabDownY = 0f
    private var grabTracking = false
    private var velocity: VelocityTracker? = null

    private fun bindGrabGesture() {
        grabHandle.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    grabDownY = event.rawY
                    grabTracking = false
                    velocity = VelocityTracker.obtain()
                    velocity?.addMovement(event)
                    cancelAnim()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    velocity?.addMovement(event)
                    val dy = event.rawY - grabDownY
                    if (!grabTracking && abs(dy) > touchSlop) {
                        grabTracking = true
                        ensureVisible()
                    }
                    if (grabTracking) {
                        val base = if (opened) 0f else -panelHeight
                        setTranslation((base + dy).coerceIn(-panelHeight, 0f))
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    velocity?.addMovement(event)
                    velocity?.computeCurrentVelocity(1000)
                    val vy = velocity?.yVelocity ?: 0f
                    velocity?.recycle(); velocity = null
                    grabTracking = false
                    settle(vy)
                    true
                }
                else -> false
            }
        }
    }

    // ---- 幕布底部热区（hint 区）：上滑收起整块幕布 ----

    private var collapseDownY = 0f
    private var collapseTracking = false
    private var collapseVelocity: VelocityTracker? = null

    /**
     * 把幕布底部（如 hint 文案区）设为收起热区：幕布打开时在此上滑可拖动收起整块面板。
     * 仅在 [opened] 时接管；收起态不拦截，保持 hint 原有行为。
     */
    fun bindCollapseZone(zone: View) {
        collapseZones.add(zone)
        zone.visibility = if (internalOpened) View.VISIBLE else View.GONE
        zone.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    if (!opened) return@setOnTouchListener false
                    collapseDownY = event.rawY
                    collapseTracking = false
                    collapseVelocity = VelocityTracker.obtain()
                    collapseVelocity?.addMovement(event)
                    cancelAnim()
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!opened) return@setOnTouchListener false
                    collapseVelocity?.addMovement(event)
                    val dy = event.rawY - collapseDownY
                    if (!collapseTracking && dy < -touchSlop) {
                        collapseTracking = true
                        ensureVisible()
                    }
                    if (collapseTracking) {
                        val base = when {
                            keyboardLift > 0f -> -keyboardLift
                            opened -> 0f
                            else -> -panelHeight
                        }
                        setTranslation((base + dy).coerceIn(-panelHeight, 0f))
                    }
                    true  // 始终 true，否则未超阈值时返回 false 会终止手势流
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    val tracked = collapseTracking
                    collapseVelocity?.addMovement(event)
                    collapseVelocity?.computeCurrentVelocity(1000)
                    val vy = collapseVelocity?.yVelocity ?: 0f
                    collapseVelocity?.recycle(); collapseVelocity = null
                    collapseTracking = false
                    if (tracked) {
                        if (collapseDownY - event.rawY > 50f * panel.resources.displayMetrics.density) {
                            close()
                        } else { settle(vy) }
                        true
                    } else false
                }
                else -> false
            }
        }
    }

    private fun ensureVisible() {
        if (panel.visibility != View.VISIBLE) {
            // 从 GONE 恢复时需先置 VISIBLE 再用缓存的高度（刚可见时 height 还为 0）。
            panel.visibility = View.VISIBLE
            shadow.visibility = View.VISIBLE
            if (panel.height > 0) panelHeight = panel.height.toFloat()
            // 刚从 GONE 恢复、尚未重新布局时，先按缓存高度置于屏幕上方，避免闪现。
            if (panelHeight <= 1f) panelHeight = panel.height.toFloat().coerceAtLeast(1f)
            panel.translationY = -panelHeight
            syncShadow()
        }
    }

    private fun setTranslation(ty: Float) {
        panel.translationY = ty.coerceIn(-panelHeight, 0f)
        syncShadow()
    }

    /**
     * 根据当前 IME 状态计算幕布应上推的高度并存储。
     * 用 [panelHeight]（缓存值）而非 panel.bottom，因为面板 GONE 时后者为 0。
     */
    fun updateKeyboardLift(rootHeight: Int, imeBottom: Int, inputHeight: Int) {
        keyboardLift = if (imeBottom > 0 && panelHeight > 0f) {
            val inputTop = rootHeight - imeBottom - inputHeight
            (panelHeight - inputTop).coerceAtLeast(0f)
        } else 0f
        updateCollapseZoneHeight()
        if (opened && !headerTracking && !grabTracking && !collapseTracking && animator?.isRunning != true) {
            panel.translationY = -keyboardLift
            syncShadow()
        }
    }

    private val Int.dp: Int get() = (this * panel.resources.displayMetrics.density).toInt()

    /** 实测幕布底边到 composer 顶部的像素距离（即 hint 区域高度）。 */
    private fun hintAreaHeight(): Int {
        val parent = panel.parent as? android.view.ViewGroup ?: return 0
        var composerTop = 0
        var panelBottom = 0
        for (i in 0 until parent.childCount) {
            val c = parent.getChildAt(i)
            if (c.id == R.id.composer_card) composerTop = c.top
            if (c.id == R.id.screen_panel) panelBottom = c.bottom
        }
        return if (composerTop > 0 && panelBottom > 0) composerTop - panelBottom else 0
    }

    /** 根据当前键盘状态更新 collapse_zone 高度。需在 panel layout 完成后调用。 */
    private fun updateCollapseZoneHeight() {
        val gap = hintAreaHeight()
        val zoneH = if (keyboardLift <= 0f) {
            if (gap > 0) 10.dp + gap else 72.dp
        } else 20.dp
        android.util.Log.d("chatput-curtain", "zoneH keyboardLift=$keyboardLift " +
            "panel.bottom=${panel.bottom} gap=$gap zoneH=$zoneH")
        collapseZones.forEach { it.layoutParams = it.layoutParams.apply { height = zoneH } }
    }

    /** 松手后按位置/速度吸附到打开或收起。 */
    private fun settle(velocityY: Float = 0f) {
        val p = progress()
        val shouldOpen = when {
            velocityY > 800f -> true
            velocityY < -800f -> false
            else -> p > 0.4f
        }
        if (shouldOpen) open() else close()
    }

    fun open() {
        collapseZones.forEach { it.visibility = View.VISIBLE }
        ensureVisible()
        // 若键盘已经弹出，动画目标直接定在输入框上方，避免先滑到 0 再跳。
        val target = if (keyboardLift > 0f) -keyboardLift else 0f
        animateTo(target) {
            internalOpened = true
            controller.start()
        }
        // 等 panel layout 完成后再测量 zone 高度（刚 VISIBLE 时 panel.bottom 还是 0）
        panel.post { updateCollapseZoneHeight() }
    }

    fun close() {
        collapseZones.forEach { it.visibility = View.GONE }
        ensureVisible()
        internalOpened = false
        controller.stop()
        animateTo(-panelHeight) {
            panel.visibility = View.GONE
            shadow.visibility = View.GONE
        }
    }

    private fun animateTo(target: Float, onEnd: () -> Unit) {
        cancelAnim()
        val from = panel.translationY
        animator = ValueAnimator.ofFloat(from, target).apply {
            duration = 280
            interpolator = DecelerateInterpolator(1.4f)
            addUpdateListener {
                panel.translationY = it.animatedValue as Float
                syncShadow()
            }
            addListener(object : android.animation.AnimatorListenerAdapter() {
                override fun onAnimationEnd(animation: android.animation.Animator) = onEnd()
            })
            start()
        }
    }

    private fun cancelAnim() { animator?.cancel(); animator = null }

    /** 页面销毁时调用。 */
    fun release() {
        cancelAnim()
        velocity?.recycle(); velocity = null
        controller.release()
    }
}
