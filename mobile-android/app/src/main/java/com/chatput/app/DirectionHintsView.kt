package com.chatput.app

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.view.View
import android.view.animation.DecelerateInterpolator
import androidx.core.content.ContextCompat

/**
 * 麦克风按钮四周的方向提示装饰（仅视觉，不拦截触摸）。
 *
 * 设计语言（与 iOS directionHints 对齐）：
 * - 四向扁角 chevron 暗示「可上下左右拖动」；左右内侧带圆点，暗示「可连续滑动」。
 * - 上下与中心距离固定；左右因留白多，chevron 不与上下对齐，而是紧挨最外侧的点。
 * - 进入连续触发：左右第二个点淡入（单点裂变为双点 = 轨迹感），chevron 随之外移一格让位。
 * - 方向聚焦：水平移光标时隐藏上下；垂直切行时隐藏左右与圆点；空闲态全显。
 * - 说话时整体淡出。
 *
 * 所有几何参数与 iOS 数值一一对应（pt≈dp）。
 */
class DirectionHintsView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : View(context, attrs, defStyleAttr) {

    private val density = resources.displayMetrics.density
    private fun dp(v: Float) = v * density

    // 与 iOS 对应的几何常量
    private val vR = dp(54f)        // 上下箭头距中心 (视觉与左右对齐)
    private val dotNear = dp(48f)   // 常驻点中心距中心 48dp
    private val dotFar = dp(55f)    // 连续态第二点
    private val chevronGap = dp(8f) // hR = 48+8 = 56 (左右箭头距中心)
    private val chevHalf = dp(6f)   // chevron 半展宽（扁平：展宽大、进深小）
    private val chevDepth = dp(3.5f)
    private val dotRadius = dp(1.5f)

    private val tintColor: Int = ContextCompat.getColor(context, R.color.chatput_accent)
    private val baseAlpha = 0.34f

    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = dp(1.5f)
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
        color = tintColor
    }
    private val dotPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = tintColor
    }
    private val path = Path()

    // 动画分量（0..1）
    private var upDownAlpha = 1f     // 上下 chevron 可见度（水平移光标时→0）
    private var leftRightAlpha = 1f  // 左右 chevron + 近点可见度（垂直切行时→0）
    private var farAlpha = 0f        // 连续态第二点可见度
    private var contFrac = 0f        // 连续态进度，驱动 chevron 外移
    private var rootAlpha = 1f       // 说话时整体淡出
    private var dotAlpha = 1f        // 圆点可见度（dpad 模式时→0）

    private var upDownAnim: ValueAnimator? = null
    private var leftRightAnim: ValueAnimator? = null
    private var farAnim: ValueAnimator? = null
    private var contAnim: ValueAnimator? = null
    private var dotAnim: ValueAnimator? = null
    private var rootAnim: ValueAnimator? = null

    /**
     * 由 ChatActivity 在状态变化时调用。
     * @param talking    正在说话（整体淡出）
     * @param cursorMode 处于光标模式
     * @param vertical   光标模式且为垂直切行（否则水平移光标）
     * @param continuous 处于连续触发
     */
    fun setState(talking: Boolean, cursorMode: Boolean, vertical: Boolean, continuous: Boolean, dpadMode: Boolean = false) {
        val horizontalActive = if (dpadMode) false else cursorMode && !vertical
        val verticalActive = if (dpadMode) false else cursorMode && vertical
        upDownAnim = animateTo(upDownAnim, upDownAlpha, if (horizontalActive) 0f else 1f) { upDownAlpha = it }
        leftRightAnim = animateTo(leftRightAnim, leftRightAlpha, if (verticalActive) 0f else 1f) { leftRightAlpha = it }
        farAnim = animateTo(farAnim, farAlpha, if (continuous && !verticalActive) 1f else 0f) { farAlpha = it }
        contAnim = animateTo(contAnim, contFrac, if (continuous) 1f else 0f) { contFrac = it }
        rootAnim = animateTo(rootAnim, rootAlpha, if (talking) 0f else 1f) { rootAlpha = it }
        val targetDot = if (dpadMode || talking) 0f else 1f
        android.util.Log.d("chatput-dots", "setState dpad=$dpadMode talking=$talking targetDot=$targetDot dotAlpha=$dotAlpha")
        dotAnim?.cancel(); dotAnim = null
        if (dotAlpha != targetDot) {
            dotAlpha = targetDot; invalidate()
        }
    }

    private fun animateTo(
        current: ValueAnimator?,
        from: Float,
        to: Float,
        apply: (Float) -> Unit
    ): ValueAnimator {
        current?.cancel()
        return ValueAnimator.ofFloat(from, to).apply {
            duration = 160
            interpolator = DecelerateInterpolator()
            addUpdateListener {
                apply(it.animatedValue as Float)
                invalidate()
            }
            start()
        }
    }

    override fun onDraw(canvas: Canvas) {
        if (rootAlpha <= 0.01f) return
        val cx = width / 2f
        val cy = height / 2f
        val hR = (dotNear + (dotFar - dotNear) * contFrac) + chevronGap

        // 上下 chevron
        drawChevron(canvas, cx, cy - vR, Dir.UP, upDownAlpha * rootAlpha)
        drawChevron(canvas, cx, cy + vR, Dir.DOWN, upDownAlpha * rootAlpha)
        // 左右 chevron
        drawChevron(canvas, cx - hR, cy, Dir.LEFT, leftRightAlpha * rootAlpha)
        drawChevron(canvas, cx + hR, cy, Dir.RIGHT, leftRightAlpha * rootAlpha)
        // 常驻近点（dpad 模式由 dotAlpha 控制隐藏）
        drawDot(canvas, cx - dotNear, cy, dotAlpha * rootAlpha)
        drawDot(canvas, cx + dotNear, cy, dotAlpha * rootAlpha)
        // 连续态第二点
        drawDot(canvas, cx - dotFar, cy, farAlpha * rootAlpha)
        drawDot(canvas, cx + dotFar, cy, farAlpha * rootAlpha)
    }

    private enum class Dir { UP, DOWN, LEFT, RIGHT }

    private fun drawChevron(canvas: Canvas, x: Float, y: Float, dir: Dir, alpha: Float) {
        if (alpha <= 0.01f) return
        path.reset()
        when (dir) {
            Dir.UP -> {
                path.moveTo(x - chevHalf, y + chevDepth)
                path.lineTo(x, y)
                path.lineTo(x + chevHalf, y + chevDepth)
            }
            Dir.DOWN -> {
                path.moveTo(x - chevHalf, y - chevDepth)
                path.lineTo(x, y)
                path.lineTo(x + chevHalf, y - chevDepth)
            }
            Dir.LEFT -> {
                path.moveTo(x + chevDepth, y - chevHalf)
                path.lineTo(x, y)
                path.lineTo(x + chevDepth, y + chevHalf)
            }
            Dir.RIGHT -> {
                path.moveTo(x - chevDepth, y - chevHalf)
                path.lineTo(x, y)
                path.lineTo(x - chevDepth, y + chevHalf)
            }
        }
        strokePaint.alpha = (baseAlpha * alpha * 255).toInt()
        canvas.drawPath(path, strokePaint)
    }

    private fun drawDot(canvas: Canvas, x: Float, y: Float, alpha: Float) {
        if (alpha <= 0.01f) return
        dotPaint.alpha = (baseAlpha * alpha * 255).toInt()
        canvas.drawCircle(x, y, dotRadius, dotPaint)
    }
}
