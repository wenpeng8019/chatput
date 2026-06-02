package com.chatput.app

import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.core.content.ContextCompat
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.card.MaterialCardView

/** 会话列表适配器（IM 会话列表风格） */
class SessionAdapter(
    private val items: List<Session>,
    private val onClick: (Session) -> Unit
) : RecyclerView.Adapter<SessionAdapter.VH>() {

    class VH(view: View) : RecyclerView.ViewHolder(view) {
        val card = view as MaterialCardView
        val app: TextView = view.findViewById(R.id.session_app)
        val title: TextView = view.findViewById(R.id.session_title)
        val accent: View = view.findViewById(R.id.session_accent)
        val badge: View = view.findViewById(R.id.session_badge)
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
        val active = s.id == ConnectionManager.activeSessionId
        holder.accent.visibility = if (active) View.VISIBLE else View.INVISIBLE
        holder.badge.visibility = if (active) View.VISIBLE else View.GONE
        val bgColor = if (active) R.color.chatput_surface_active else R.color.chatput_surface
        val strokeColor = if (active) R.color.chatput_accent_soft else R.color.chatput_line
        holder.card.setCardBackgroundColor(ContextCompat.getColor(holder.itemView.context, bgColor))
        holder.card.strokeColor = ContextCompat.getColor(holder.itemView.context, strokeColor)

        holder.itemView.setOnClickListener { onClick(s) }
    }

    override fun getItemCount(): Int = items.size
}


