package com.chatput.app

import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.util.AttributeSet
import androidx.appcompat.widget.AppCompatTextView

/**
 * 给文字加一圈柔和的白色光晕（halo），保证在任意背景上都清晰可读，
 * 但不改变字重：先用本体字形画一层带模糊的白色阴影做光晕，再原位填充本体颜色。
 * 由于两遍都是 FILL 且字形位置一致，白色完全被本体色覆盖，只在边缘透出光晕。
 */
class OutlineTextView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
    defStyleAttr: Int = 0
) : AppCompatTextView(context, attrs, defStyleAttr) {

    private val haloRadiusPx = 3f * resources.displayMetrics.density

    override fun onDraw(canvas: Canvas) {
        val p: Paint = paint
        val fillColor = currentTextColor

        // 第一遍：白色字形 + 白色模糊阴影 → 形成柔和光晕。
        p.style = Paint.Style.FILL
        p.color = Color.WHITE
        p.setShadowLayer(haloRadiusPx, 0f, 0f, Color.WHITE)
        super.onDraw(canvas)
        super.onDraw(canvas)   // 叠两遍让光晕更实，边缘更连贯

        // 第二遍：原位填充本体颜色，覆盖白色字身，仅保留边缘光晕。
        p.clearShadowLayer()
        p.color = fillColor
        super.onDraw(canvas)
    }
}

