package com.remoteinput.app

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
        holder.itemView.setOnClickListener { onClick(s) }
    }

    override fun getItemCount(): Int = items.size
}
