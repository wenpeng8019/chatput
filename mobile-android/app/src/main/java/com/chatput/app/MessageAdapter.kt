package com.chatput.app

import android.annotation.SuppressLint
import android.view.GestureDetector
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

/** 消息列表适配器（仅展示发出的语音文本） */
class MessageAdapter(
    private val items: List<ChatMessage>,
    /** 双击气泡：重新发送（不新增历史项） */
    private val onResend: (View, Int) -> Unit = { _, _ -> },
    /** 长按气泡：弹出操作菜单 */
    private val onLongPress: (View, Int) -> Unit = { _, _ -> }
) : RecyclerView.Adapter<MessageAdapter.VH>() {

    inner class VH(view: View) : RecyclerView.ViewHolder(view) {
        val text: TextView = view.findViewById(R.id.msg_text)

        private val detector = GestureDetector(
            view.context,
            object : GestureDetector.SimpleOnGestureListener() {
                override fun onDown(e: MotionEvent): Boolean = true

                override fun onDoubleTap(e: MotionEvent): Boolean {
                    val pos = bindingAdapterPosition
                    if (pos != RecyclerView.NO_POSITION) onResend(text, pos)
                    return true
                }

                override fun onLongPress(e: MotionEvent) {
                    val pos = bindingAdapterPosition
                    if (pos != RecyclerView.NO_POSITION) onLongPress(text, pos)
                }
            }
        )

        @SuppressLint("ClickableViewAccessibility")
        fun bindGestures() {
            text.setOnTouchListener { _, event -> detector.onTouchEvent(event) }
        }
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_message, parent, false)
        return VH(v).also { it.bindGestures() }
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        holder.text.text = items[position].text
    }

    override fun getItemCount(): Int = items.size
}
