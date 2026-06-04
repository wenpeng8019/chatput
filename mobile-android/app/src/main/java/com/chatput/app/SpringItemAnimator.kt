package com.chatput.app

import android.view.View
import androidx.dynamicanimation.animation.DynamicAnimation
import androidx.dynamicanimation.animation.SpringAnimation
import androidx.dynamicanimation.animation.SpringForce
import androidx.recyclerview.widget.RecyclerView
import androidx.recyclerview.widget.SimpleItemAnimator

/**
 * 列表增删动效：全程弹簧物理，观感对齐 iOS spring。
 * - 位移（move）：SpringAnimation 驱动 translationX/Y → 0，周围项弹性让位（流畅感核心）。
 * - 新增：scale 0.9 + alpha 0 → 1，弹簧缩放回弹。
 * - 删除：scale → 0.9 + alpha → 0。
 * 增删与位移并行，统一时间线。
 */
class SpringItemAnimator : SimpleItemAnimator() {

    private val pendingAdds = ArrayList<RecyclerView.ViewHolder>()
    private val pendingRemoves = ArrayList<RecyclerView.ViewHolder>()
    private val pendingMoves = ArrayList<MoveInfo>()
    private val pendingChanges = ArrayList<ChangeInfo>()

    private val running = HashSet<RecyclerView.ViewHolder>()

    private val enterStartScale = 0.9f

    // 位移弹簧：略带回弹、较快收敛，接近 iOS spring(response:0.35, damping:0.8)。
    private val moveStiffness = SpringForce.STIFFNESS_LOW * 1.4f
    private val moveDamping = 0.78f
    // 缩放弹簧：回弹更明显（新增项更有“弹出”感）。
    private val scaleStiffness = SpringForce.STIFFNESS_MEDIUM
    private val scaleDamping = 0.62f

    init {
        addDuration = 260
        removeDuration = 200
        moveDuration = 320
        changeDuration = 220
    }

    private data class MoveInfo(
        val holder: RecyclerView.ViewHolder,
        val fromX: Int, val fromY: Int, val toX: Int, val toY: Int
    )

    private data class ChangeInfo(
        val oldHolder: RecyclerView.ViewHolder?,
        val newHolder: RecyclerView.ViewHolder?
    )

    override fun animateAdd(holder: RecyclerView.ViewHolder): Boolean {
        endAnimation(holder)
        holder.itemView.alpha = 0f
        holder.itemView.scaleX = enterStartScale
        holder.itemView.scaleY = enterStartScale
        pendingAdds.add(holder)
        return true
    }

    override fun animateRemove(holder: RecyclerView.ViewHolder): Boolean {
        endAnimation(holder)
        pendingRemoves.add(holder)
        return true
    }

    override fun animateMove(
        holder: RecyclerView.ViewHolder,
        fromX: Int, fromY: Int, toX: Int, toY: Int
    ): Boolean {
        val view = holder.itemView
        val dx = toX - fromX - view.translationX.toInt()
        val dy = toY - fromY - view.translationY.toInt()
        if (dx == 0 && dy == 0) {
            dispatchMoveFinished(holder)
            return false
        }
        if (dx != 0) view.translationX = (-dx).toFloat()
        if (dy != 0) view.translationY = (-dy).toFloat()
        pendingMoves.add(MoveInfo(holder, fromX, fromY, toX, toY))
        return true
    }

    override fun animateChange(
        oldHolder: RecyclerView.ViewHolder,
        newHolder: RecyclerView.ViewHolder,
        fromX: Int, fromY: Int, toX: Int, toY: Int
    ): Boolean {
        if (oldHolder === newHolder) {
            // 同一 ViewHolder 内容变化（如 isActive 翻转）：直接结束，避免闪烁。
            dispatchChangeFinished(oldHolder, true)
            return false
        }
        pendingChanges.add(ChangeInfo(oldHolder, newHolder))
        return true
    }

    override fun runPendingAnimations() {
        val hasRemoves = pendingRemoves.isNotEmpty()
        val hasMoves = pendingMoves.isNotEmpty()
        val hasChanges = pendingChanges.isNotEmpty()
        val hasAdds = pendingAdds.isNotEmpty()
        if (!hasRemoves && !hasMoves && !hasChanges && !hasAdds) return

        // 删除先行
        for (holder in pendingRemoves) animateRemoveImpl(holder)
        pendingRemoves.clear()

        // 位移
        if (hasMoves) {
            val moves = ArrayList(pendingMoves)
            pendingMoves.clear()
            for (m in moves) animateMoveImpl(m)
        }

        // 内容变化
        if (hasChanges) {
            val changes = ArrayList(pendingChanges)
            pendingChanges.clear()
            for (c in changes) animateChangeImpl(c)
        }

        // 新增（增删并行，更接近 iOS 的统一时间线）
        if (hasAdds) {
            val adds = ArrayList(pendingAdds)
            pendingAdds.clear()
            for (holder in adds) animateAddImpl(holder)
        }
    }

    private fun spring(
        view: View,
        property: DynamicAnimation.ViewProperty,
        finalValue: Float,
        stiffness: Float,
        damping: Float,
        onEnd: () -> Unit
    ): SpringAnimation {
        return SpringAnimation(view, property, finalValue).apply {
            spring = SpringForce(finalValue).apply {
                this.stiffness = stiffness
                dampingRatio = damping
            }
            addEndListener { _, _, _, _ -> onEnd() }
        }
    }

    private fun animateAddImpl(holder: RecyclerView.ViewHolder) {
        val view = holder.itemView
        running.add(holder)
        dispatchAddStarting(holder)
        var remaining = 3
        val done = {
            remaining--
            if (remaining == 0) {
                view.alpha = 1f; view.scaleX = 1f; view.scaleY = 1f
                running.remove(holder)
                dispatchAddFinished(holder)
                dispatchFinishedWhenDone()
            }
        }
        spring(view, DynamicAnimation.SCALE_X, 1f, scaleStiffness, scaleDamping, done).start()
        spring(view, DynamicAnimation.SCALE_Y, 1f, scaleStiffness, scaleDamping, done).start()
        spring(view, DynamicAnimation.ALPHA, 1f, SpringForce.STIFFNESS_MEDIUM, 1f, done).start()
    }

    private fun animateRemoveImpl(holder: RecyclerView.ViewHolder) {
        val view = holder.itemView
        running.add(holder)
        dispatchRemoveStarting(holder)
        view.animate()
            .alpha(0f)
            .scaleX(enterStartScale)
            .scaleY(enterStartScale)
            .setDuration(removeDuration)
            .withEndAction {
                view.alpha = 1f; view.scaleX = 1f; view.scaleY = 1f
                running.remove(holder)
                dispatchRemoveFinished(holder)
                dispatchFinishedWhenDone()
            }
            .start()
    }

    private fun animateMoveImpl(m: MoveInfo) {
        val view = m.holder.itemView
        running.add(m.holder)
        dispatchMoveStarting(m.holder)
        val needX = view.translationX != 0f
        val needY = view.translationY != 0f
        var remaining = (if (needX) 1 else 0) + (if (needY) 1 else 0)
        if (remaining == 0) {
            running.remove(m.holder)
            dispatchMoveFinished(m.holder)
            dispatchFinishedWhenDone()
            return
        }
        val done = {
            remaining--
            if (remaining == 0) {
                view.translationX = 0f; view.translationY = 0f
                running.remove(m.holder)
                dispatchMoveFinished(m.holder)
                dispatchFinishedWhenDone()
            }
        }
        if (needX) spring(view, DynamicAnimation.TRANSLATION_X, 0f, moveStiffness, moveDamping, done).start()
        if (needY) spring(view, DynamicAnimation.TRANSLATION_Y, 0f, moveStiffness, moveDamping, done).start()
    }

    private fun animateChangeImpl(c: ChangeInfo) {
        c.oldHolder?.let { dispatchChangeFinished(it, true) }
        c.newHolder?.let { dispatchChangeFinished(it, false) }
        dispatchFinishedWhenDone()
    }

    override fun endAnimation(holder: RecyclerView.ViewHolder) {
        val view = holder.itemView
        view.animate().cancel()
        if (pendingRemoves.remove(holder)) {
            dispatchRemoveFinished(holder)
        }
        if (pendingAdds.remove(holder)) {
            view.alpha = 1f
            view.scaleX = 1f
            view.scaleY = 1f
            dispatchAddFinished(holder)
        }
        pendingMoves.removeAll { it.holder === holder }
        view.translationX = 0f
        view.translationY = 0f
        view.alpha = 1f
        view.scaleX = 1f
        view.scaleY = 1f
        running.remove(holder)
        dispatchFinishedWhenDone()
    }

    override fun endAnimations() {
        for (holder in ArrayList(pendingAdds)) endAnimation(holder)
        for (holder in ArrayList(pendingRemoves)) endAnimation(holder)
        for (m in ArrayList(pendingMoves)) endAnimation(m.holder)
        dispatchAnimationsFinished()
    }

    override fun isRunning(): Boolean {
        return running.isNotEmpty() || pendingAdds.isNotEmpty() ||
            pendingRemoves.isNotEmpty() || pendingMoves.isNotEmpty() ||
            pendingChanges.isNotEmpty()
    }

    private fun dispatchFinishedWhenDone() {
        if (!isRunning) dispatchAnimationsFinished()
    }
}
