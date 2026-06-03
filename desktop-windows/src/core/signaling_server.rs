//! 内置 WebSocket 信令服务器（tokio-tungstenite）。
//! 与 `signaling-server/src/index.js` 协议完全一致，零外部依赖，用于局域网内置模式。
//!
//! 协议（JSON 文本帧）：
//!   C->S {type:'create-room'}                  -> S->C {type:'room-created', roomId, token}
//!   C->S {type:'join-room', roomId, token}     -> 双方: {type:'peer-joined', role}
//!   C->S {type:'signal', data}                 -> 原样转发给房间内另一端
//!   C->S {type:'message', data}                -> 业务消息中继给房间内另一端
//!   S->C {type:'peer-left'}                     某端断开时通知另一端

use crate::core::wire;
use futures_util::{SinkExt, StreamExt};
use rand::RngCore;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use tokio::net::TcpListener;
use tokio::sync::{mpsc, Mutex};
use tokio_tungstenite::tungstenite::Message;

/// 服务器状态/日志事件。
pub enum ServerEvent {
    /// running, port
    State(bool, u16),
    Error(String),
    Log(String),
}

type ClientId = u64;
type ClientSink = mpsc::UnboundedSender<Message>;

#[derive(Default)]
struct Room {
    token: String,
    host: Option<ClientId>,
    guest: Option<ClientId>,
}

#[derive(Default)]
struct Shared {
    clients: HashMap<ClientId, ClientSink>,
    client_room: HashMap<ClientId, String>,
    rooms: HashMap<String, Room>,
}

/// 内置信令服务器。`start` 在指定端口监听，`stop` 关闭。
pub struct SignalingServer {
    events: mpsc::UnboundedSender<ServerEvent>,
    shutdown: Arc<Mutex<Option<tokio::sync::oneshot::Sender<()>>>>,
    shared: Arc<Mutex<Shared>>,
    next_id: Arc<std::sync::atomic::AtomicU64>,
}

impl SignalingServer {
    pub fn new(events: mpsc::UnboundedSender<ServerEvent>) -> Self {
        SignalingServer {
            events,
            shutdown: Arc::new(Mutex::new(None)),
            shared: Arc::new(Mutex::new(Shared::default())),
            next_id: Arc::new(std::sync::atomic::AtomicU64::new(1)),
        }
    }

    /// 在指定端口启动。若已在运行会先停止。
    pub async fn start(&self, port: u16) {
        self.stop().await;

        let listener = match TcpListener::bind(("0.0.0.0", port)).await {
            Ok(l) => l,
            Err(_) => {
                let _ = self
                    .events
                    .send(ServerEvent::Error(format!("端口 {} 监听失败（可能被占用）", port)));
                let _ = self.events.send(ServerEvent::State(false, 0));
                return;
            }
        };

        let (tx_shutdown, mut rx_shutdown) = tokio::sync::oneshot::channel::<()>();
        *self.shutdown.lock().await = Some(tx_shutdown);

        let _ = self.events.send(ServerEvent::State(true, port));
        let _ = self
            .events
            .send(ServerEvent::Log(format!("信令服务器已启动 ws://0.0.0.0:{}", port)));

        let shared = self.shared.clone();
        let next_id = self.next_id.clone();
        let events = self.events.clone();

        tokio::spawn(async move {
            loop {
                tokio::select! {
                    _ = &mut rx_shutdown => {
                        break;
                    }
                    accepted = listener.accept() => {
                        match accepted {
                            Ok((stream, _addr)) => {
                                let id = next_id.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                                let shared = shared.clone();
                                tokio::spawn(handle_connection(stream, id, shared));
                            }
                            Err(_) => break,
                        }
                    }
                }
            }
            // 关闭：清理所有客户端与房间。
            let mut g = shared.lock().await;
            g.clients.clear();
            g.client_room.clear();
            g.rooms.clear();
            let _ = events.send(ServerEvent::Log("信令服务器已停止".to_string()));
            let _ = events.send(ServerEvent::State(false, 0));
        });
    }

    pub async fn stop(&self) {
        if let Some(tx) = self.shutdown.lock().await.take() {
            let _ = tx.send(());
        }
    }
}

async fn handle_connection(
    stream: tokio::net::TcpStream,
    id: ClientId,
    shared: Arc<Mutex<Shared>>,
) {
    let ws = match tokio_tungstenite::accept_async(stream).await {
        Ok(ws) => ws,
        Err(_) => return,
    };
    let (mut write, mut read) = ws.split();
    let (tx, mut rx) = mpsc::unbounded_channel::<Message>();

    shared.lock().await.clients.insert(id, tx);

    // 发送任务。
    let send_task = tokio::spawn(async move {
        while let Some(msg) = rx.recv().await {
            if write.send(msg).await.is_err() {
                break;
            }
        }
    });

    while let Some(item) = read.next().await {
        match item {
            Ok(Message::Text(text)) => {
                handle_message(&text, id, &shared).await;
            }
            Ok(Message::Binary(bin)) => {
                if let Ok(text) = String::from_utf8(bin) {
                    handle_message(&text, id, &shared).await;
                }
            }
            Ok(Message::Close(_)) | Err(_) => break,
            _ => {}
        }
    }

    cleanup(id, &shared).await;
    send_task.abort();
}

async fn handle_message(text: &str, id: ClientId, shared: &Arc<Mutex<Shared>>) {
    let obj: Value = match serde_json::from_str(text) {
        Ok(v) => v,
        Err(_) => {
            send_to(shared, id, &json!({"type": wire::signal::ERROR, "reason": wire::reason::INVALID_JSON})).await;
            return;
        }
    };
    let msg_type = obj.get(wire::key::TYPE).and_then(|v| v.as_str()).unwrap_or("");

    match msg_type {
        t if t == wire::signal::CREATE_ROOM => {
            let room_id = gen_id(3);
            let token = gen_id(8);
            {
                let mut g = shared.lock().await;
                g.rooms.insert(
                    room_id.clone(),
                    Room {
                        token: token.clone(),
                        host: Some(id),
                        guest: None,
                    },
                );
                g.client_room.insert(id, room_id.clone());
            }
            send_to(
                shared,
                id,
                &json!({"type": wire::signal::ROOM_CREATED, "roomId": room_id, "token": token}),
            )
            .await;
        }

        t if t == wire::signal::JOIN_ROOM => {
            let room_id = obj.get("roomId").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let token = obj.get("token").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let mut host_id: Option<ClientId> = None;
            let result_reason = {
                let mut g = shared.lock().await;
                match g.rooms.get_mut(&room_id) {
                    None => Some(wire::reason::ROOM_NOT_FOUND),
                    Some(room) if room.token != token => Some(wire::reason::BAD_TOKEN),
                    Some(room) if room.guest.is_some() => Some(wire::reason::ROOM_FULL),
                    Some(room) => {
                        room.guest = Some(id);
                        host_id = room.host;
                        None
                    }
                }
            };
            match result_reason {
                Some(reason) => {
                    send_to(shared, id, &json!({"type": wire::signal::ERROR, "reason": reason})).await;
                }
                None => {
                    shared.lock().await.client_room.insert(id, room_id.clone());
                    send_to(shared, id, &json!({"type": wire::signal::PEER_JOINED, "role": wire::role::GUEST})).await;
                    if let Some(hid) = host_id {
                        send_to(shared, hid, &json!({"type": wire::signal::PEER_JOINED, "role": wire::role::HOST})).await;
                    }
                }
            }
        }

        t if t == wire::signal::SIGNAL => {
            if let Some(peer) = other_peer(shared, id).await {
                if let Some(data) = obj.get("data") {
                    send_to(shared, peer, &json!({"type": wire::signal::SIGNAL, "data": data})).await;
                }
            } else {
                send_to(shared, id, &json!({"type": wire::signal::ERROR, "reason": wire::reason::NOT_IN_ROOM})).await;
            }
        }

        t if t == wire::signal::MESSAGE => {
            if let Some(peer) = other_peer(shared, id).await {
                if let Some(data) = obj.get(wire::key::DATA) {
                    send_to(shared, peer, &json!({wire::key::TYPE: wire::signal::MESSAGE, wire::key::DATA: data})).await;
                }
            } else {
                send_to(shared, id, &json!({"type": wire::signal::ERROR, "reason": wire::reason::NOT_IN_ROOM})).await;
            }
        }

        _ => {
            send_to(shared, id, &json!({"type": wire::signal::ERROR, "reason": wire::reason::UNKNOWN_TYPE})).await;
        }
    }
}

async fn other_peer(shared: &Arc<Mutex<Shared>>, id: ClientId) -> Option<ClientId> {
    let g = shared.lock().await;
    let room_id = g.client_room.get(&id)?;
    let room = g.rooms.get(room_id)?;
    if room.host == Some(id) {
        room.guest
    } else if room.guest == Some(id) {
        room.host
    } else {
        None
    }
}

async fn cleanup(id: ClientId, shared: &Arc<Mutex<Shared>>) {
    let peer = other_peer(shared, id).await;
    {
        let mut g = shared.lock().await;
        g.clients.remove(&id);
        if let Some(room_id) = g.client_room.remove(&id) {
            let mut remove_room = false;
            if let Some(room) = g.rooms.get_mut(&room_id) {
                if room.host == Some(id) {
                    room.host = None;
                }
                if room.guest == Some(id) {
                    room.guest = None;
                }
                remove_room = room.host.is_none() && room.guest.is_none();
            }
            if remove_room {
                g.rooms.remove(&room_id);
            }
        }
    }
    if let Some(peer) = peer {
        send_to(shared, peer, &json!({"type": wire::signal::PEER_LEFT})).await;
    }
}

async fn send_to(shared: &Arc<Mutex<Shared>>, id: ClientId, obj: &Value) {
    let sink = {
        let g = shared.lock().await;
        g.clients.get(&id).cloned()
    };
    if let Some(sink) = sink {
        let _ = sink.send(Message::Text(obj.to_string()));
    }
}

fn gen_id(bytes: usize) -> String {
    let mut buf = vec![0u8; bytes];
    rand::thread_rng().fill_bytes(&mut buf);
    buf.iter().map(|b| format!("{:02x}", b)).collect()
}
