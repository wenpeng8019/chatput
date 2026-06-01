package com.chatput.app

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

/** 消息列表适配器（仅展示发出的语音文本） */
class MessageAdapter(
    private val items: List<ChatMessage>
) : RecyclerView.Adapter<MessageAdapter.VH>() {

    class VH(view: View) : RecyclerView.ViewHolder(view) {
        val text: TextView = view.findViewById(R.id.msg_text)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_message, parent, false)
        return VH(v)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        holder.text.text = items[position].text
    }

    override fun getItemCount(): Int = items.size
}
