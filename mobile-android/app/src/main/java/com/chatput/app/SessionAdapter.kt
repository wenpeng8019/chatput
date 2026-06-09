package com.chatput.app

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.DiffUtil
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.card.MaterialCardView

/** 会话列表适配器（IM 会话列表风格） */
class SessionAdapter(
    initial: List<Session>,
    private val onClick: (Session) -> Unit
) : RecyclerView.Adapter<SessionAdapter.VH>() {

    // 持有内部快照；通过 submit() 用 DiffUtil 派发逐项增删/位移通知，触发默认动效。
    private val items: MutableList<Session> = initial.toMutableList()
    // Session 为可变对象且被原地修改，diff 必须基于提交时刻的字段值快照而非对象引用。
    private var snapshots: List<Snap> = initial.map { Snap(it) }

    private data class Snap(
        val connectionId: String,
        val id: String,
        val app: String,
        val title: String,
        val device: String,
        val isActive: Boolean
    ) {
        constructor(s: Session) : this(s.connectionId, s.id, s.app, s.title, s.device, s.isActive)
    }

    class VH(view: View) : RecyclerView.ViewHolder(view) {
        val card = view as MaterialCardView
        val app: TextView = view.findViewById(R.id.session_app)
        val title: TextView = view.findViewById(R.id.session_title)
        val accent: View = view.findViewById(R.id.session_accent)
        val badge: View = view.findViewById(R.id.session_badge)
    }

    /** 用 DiffUtil 计算差异并派发，使增删/移动/内容变化各自走默认动画。 */
    fun submit(newList: List<Session>) {
        val old = snapshots
        val new = newList.map { Snap(it) }
        val diff = DiffUtil.calculateDiff(object : DiffUtil.Callback() {
            override fun getOldListSize() = old.size
            override fun getNewListSize() = new.size
            override fun areItemsTheSame(o: Int, n: Int): Boolean =
                old[o].connectionId == new[n].connectionId && old[o].id == new[n].id
            override fun areContentsTheSame(o: Int, n: Int): Boolean = old[o] == new[n]
        })
        items.clear()
        items.addAll(newList)
        snapshots = new
        diff.dispatchUpdatesTo(this)
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val v = LayoutInflater.from(parent.context)
            .inflate(R.layout.item_session, parent, false)
        return VH(v)
    }

    override fun onBindViewHolder(holder: VH, position: Int) {
        val s = items[position]
        holder.app.text = s.app.ifBlank { "未知应用" }
        holder.title.text = s.device.ifBlank { s.title.ifBlank { "当前窗口" } }

        // 桌面端当前聚焦的会话：高亮 + 焦点徽标
        val active = s.isActive
        holder.accent.visibility = if (active) View.VISIBLE else View.INVISIBLE
        holder.badge.visibility = if (active) View.VISIBLE else View.GONE
        val bgColor = if (active) R.color.chatput_surface_active else R.color.chatput_surface
        val strokeColor = ContextCompat.getColor(holder.itemView.context,
            if (active) R.color.chatput_accent else R.color.chatput_line)
        holder.card.setCardBackgroundColor(ContextCompat.getColor(holder.itemView.context, bgColor))
        holder.card.strokeColor = if (active) (strokeColor and 0x00FFFFFF) or (0x4D shl 24) else strokeColor

        holder.itemView.setOnClickListener { onClick(s) }
    }

    override fun getItemCount(): Int = items.size
}


