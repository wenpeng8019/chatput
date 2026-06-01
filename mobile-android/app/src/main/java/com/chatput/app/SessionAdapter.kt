package com.chatput.app

import android.graphics.Color
import android.util.TypedValue
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import androidx.recyclerview.widget.RecyclerView

/** 会话列表适配器（IM 会话列表风格） */
class SessionAdapter(
    private val items: List<Session>,
    private val onClick: (Session) -> Unit
) : RecyclerView.Adapter<SessionAdapter.VH>() {

    class VH(view: View) : RecyclerView.ViewHolder(view) {
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
        holder.title.text = s.title.ifBlank { "(无标题)" }

        // 桌面端当前聚焦的会话：高亮 + 焦点徽标
        val active = s.id == ConnectionManager.activeSessionId
        holder.accent.visibility = if (active) View.VISIBLE else View.INVISIBLE
        holder.badge.visibility = if (active) View.VISIBLE else View.GONE
        if (active) {
            holder.itemView.setBackgroundColor(ACTIVE_BG)
        } else {
            holder.itemView.setBackgroundResource(selectableBackground(holder.itemView))
        }

        holder.itemView.setOnClickListener { onClick(s) }
    }

    override fun getItemCount(): Int = items.size

    private fun selectableBackground(view: View): Int {
        val tv = TypedValue()
        view.context.theme.resolveAttribute(
            android.R.attr.selectableItemBackground, tv, true
        )
        return tv.resourceId
    }

    private companion object {
        val ACTIVE_BG = Color.parseColor("#F2F6FF")
    }
}


