//! 信令 WebSocket 客户端（tokio-tungstenite）。
//! 协议与 signaling-server 一致：JSON 文本帧。

use futures_util::{SinkExt, StreamExt};
use serde_json::Value;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::sync::Mutex;
use tokio_tungstenite::connect_async;
use tokio_tungstenite::tungstenite::Message;

/// 信令客户端事件。
pub enum SignalingEvent {
    Open,
    Message(Value),
    Close,
}

/// 异步 WebSocket 客户端。`connect` 后通过 event channel 输出事件，
/// 通过 `send` 发送 JSON。
pub struct SignalingClient {
    out_tx: Arc<Mutex<Option<mpsc::UnboundedSender<Message>>>>,
    generation: Arc<std::sync::atomic::AtomicU64>,
    events: mpsc::UnboundedSender<SignalingEvent>,
}

impl SignalingClient {
    pub fn new(events: mpsc::UnboundedSender<SignalingEvent>) -> Self {
        SignalingClient {
            out_tx: Arc::new(Mutex::new(None)),
            generation: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            events,
        }
    }

    /// 连接到指定 ws 地址。会先关闭旧连接。
    pub async fn connect(&self, url: String) {
        if url.is_empty() {
            return;
        }
        // 递增代号，旧任务发现代号变化即退出。
        let gen = self
            .generation
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst)
            + 1;

        let (ws_stream, _) = match connect_async(&url).await {
            Ok(s) => s,
            Err(_) => {
                let _ = self.events.send(SignalingEvent::Close);
                return;
            }
        };

        let (mut write, mut read) = ws_stream.split();
        let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
        *self.out_tx.lock().await = Some(tx);

        let _ = self.events.send(SignalingEvent::Open);

        // 发送任务。
        let gen_check = self.generation.clone();
        let gen_send = gen;
        tokio::spawn(async move {
            while let Some(msg) = rx.recv().await {
                if gen_check.load(std::sync::atomic::Ordering::SeqCst) != gen_send {
                    break;
                }
                if write.send(msg).await.is_err() {
                    break;
                }
            }
        });

        // 接收任务。
        let events = self.events.clone();
        let gen_check2 = self.generation.clone();
        tokio::spawn(async move {
            while let Some(item) = read.next().await {
                if gen_check2.load(std::sync::atomic::Ordering::SeqCst) != gen {
                    return;
                }
                match item {
                    Ok(Message::Text(text)) => {
                        if let Ok(v) = serde_json::from_str::<Value>(&text) {
                            let _ = events.send(SignalingEvent::Message(v));
                        }
                    }
                    Ok(Message::Binary(bin)) => {
                        if let Ok(v) = serde_json::from_slice::<Value>(&bin) {
                            let _ = events.send(SignalingEvent::Message(v));
                        }
                    }
                    Ok(Message::Close(_)) | Err(_) => break,
                    _ => {}
                }
            }
            if gen_check2.load(std::sync::atomic::Ordering::SeqCst) == gen {
                let _ = events.send(SignalingEvent::Close);
            }
        });
    }

    /// 发送一个 JSON 对象。
    pub async fn send(&self, obj: &Value) {
        if let Some(tx) = self.out_tx.lock().await.as_ref() {
            let _ = tx.send(Message::Text(obj.to_string()));
        }
    }

    /// 关闭当前连接。
    pub async fn close(&self) {
        self.generation
            .fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        *self.out_tx.lock().await = None;
    }
}
