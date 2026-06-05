package com.chatput.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * 缩略地图：底图是被控窗口的整窗缩略图，上面一个红框表示手机当前查看的子区域。
 * 拖动红框即移动采集区域（效果如游戏小地图）。坐标对外一律用「窗口像素」。
 */
class MinimapView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyle: Int = 0
) : View(context, attrs, defStyle) {

    /** 拖动红框时回调新的视口左上角（窗口像素，已钳制）。 */
    var onViewportMove: ((x: Int, y: Int) -> Unit)? = null
    /** 长按缩略图时回调，用于弹出位置设置菜单。 */
    var onLongPress: (() -> Unit)? = null

    private var thumbnail: Bitmap? = null
    private var winW = 0
    private var winH = 0

    // 视口（窗口像素）
    private var vpX = 0f
    private var vpY = 0f
    private var vpW = 0f
    private var vpH = 0f

    // 底图在本 View 内的实际绘制矩形（letterbox 后）
    private val contentRect = RectF()

    private val boxPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        color = Color.parseColor("#FF3B30")
        strokeWidth = 3f * resources.displayMetrics.density
    }
    private val boxFillPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.FILL
        color = Color.parseColor("#33FF3B30")
    }
    private val bgPaint = Paint().apply { color = Color.parseColor("#11000000") }

    private var dragging = false
    private var dragDx = 0f
    private var dragDy = 0f
    private var downX = 0f
    private var downY = 0f

    private val touchSlop = ViewConfiguration.get(context).scaledTouchSlop.toFloat()
    private val longPressTimeout = ViewConfiguration.getLongPressTimeout().toLong()
    private val longPressRunnable = Runnable { onLongPress?.invoke() }
    private var longPressPending = false

    /** 设置整窗缩略图（贴图）。窗口像素尺寸以 screen-meta 为准，不取 JPEG 像素。 */
    fun setThumbnail(bitmap: Bitmap) {
        thumbnail = bitmap
        recomputeContentRect()
        invalidate()
    }

    /** 由桌面端 screen-meta 回填权威窗口尺寸与实际生效视口（窗口像素）。 */
    fun setMeta(windowW: Int, windowH: Int, x: Int, y: Int, w: Int, h: Int) {
        winW = windowW
        winH = windowH
        vpX = x.toFloat(); vpY = y.toFloat(); vpW = w.toFloat(); vpH = h.toFloat()
        recomputeContentRect()
        invalidate()
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        recomputeContentRect()
    }

    private fun recomputeContentRect() {
        if (winW <= 0 || winH <= 0 || width == 0 || height == 0) return
        val viewAspect = width.toFloat() / height
        val winAspect = winW.toFloat() / winH
        if (winAspect > viewAspect) {
            val drawH = width / winAspect
            val top = (height - drawH) / 2f
            contentRect.set(0f, top, width.toFloat(), top + drawH)
        } else {
            val drawW = height * winAspect
            val left = (width - drawW) / 2f
            contentRect.set(left, 0f, left + drawW, height.toFloat())
        }
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val bmp = thumbnail ?: return
        if (contentRect.isEmpty) return
        canvas.drawRect(contentRect, bgPaint)
        canvas.drawBitmap(bmp, null, contentRect, null)

        if (winW <= 0 || winH <= 0 || vpW <= 0 || vpH <= 0) return
        val sx = contentRect.width() / winW
        val sy = contentRect.height() / winH
        val box = RectF(
            contentRect.left + vpX * sx,
            contentRect.top + vpY * sy,
            contentRect.left + (vpX + vpW) * sx,
            contentRect.top + (vpY + vpH) * sy
        )
        canvas.drawRect(box, boxFillPaint)
        canvas.drawRect(box, boxPaint)
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (winW <= 0 || winH <= 0 || vpW <= 0 || vpH <= 0 || contentRect.isEmpty) return false
        val sx = contentRect.width() / winW
        val sy = contentRect.height() / winH
        val boxLeft = contentRect.left + vpX * sx
        val boxTop = contentRect.top + vpY * sy
        val boxRight = boxLeft + vpW * sx
        val boxBottom = boxTop + vpH * sy

        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = event.x; downY = event.y
                longPressPending = true
                postDelayed(longPressRunnable, longPressTimeout)
                val inside = event.x in boxLeft..boxRight && event.y in boxTop..boxBottom
                if (inside) {
                    dragging = true
                    parent?.requestDisallowInterceptTouchEvent(true)
                    dragDx = event.x - boxLeft
                    dragDy = event.y - boxTop
                }
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (longPressPending && hypot(event.x - downX, event.y - downY) > touchSlop) {
                    removeCallbacks(longPressRunnable)
                    longPressPending = false
                }
                if (!dragging) return true
                moveBoxTo(event.x, event.y, sx, sy)
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                removeCallbacks(longPressRunnable)
                longPressPending = false
                dragging = false
                parent?.requestDisallowInterceptTouchEvent(false)
                return true
            }
        }
        return false
    }

    /** 把红框左上角移到使其(由 dragDx/dragDy 决定的)抓点对齐到触点处，并钳制。 */
    private fun moveBoxTo(touchX: Float, touchY: Float, sx: Float, sy: Float) {
        val newLeftView = touchX - dragDx
        val newTopView = touchY - dragDy
        val newX = (newLeftView - contentRect.left) / sx
        val newY = (newTopView - contentRect.top) / sy
        val clampedX = max(0f, min(newX, (winW - vpW)))
        val clampedY = max(0f, min(newY, (winH - vpH)))
        vpX = clampedX
        vpY = clampedY
        invalidate()
        onViewportMove?.invoke(clampedX.toInt(), clampedY.toInt())
    }
}
