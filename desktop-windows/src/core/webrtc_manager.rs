//! 桌面端 WebRTC HOST（webrtc-rs）。
//! 创建 PeerConnection 与 "input" DataChannel，发 offer，收 answer/candidate，
//! 通过 DataChannel 收手机的 text/action/hello、发 session。

use crate::core::wire;
use serde_json::{json, Value};
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::sync::Mutex;

use webrtc::api::interceptor_registry::register_default_interceptors;
use webrtc::api::media_engine::MediaEngine;
use webrtc::api::APIBuilder;
use webrtc::data_channel::data_channel_message::DataChannelMessage;
use webrtc::data_channel::RTCDataChannel;
use webrtc::ice_transport::ice_candidate::RTCIceCandidateInit;
use webrtc::ice_transport::ice_connection_state::RTCIceConnectionState;
use webrtc::ice_transport::ice_server::RTCIceServer;
use webrtc::interceptor::registry::Registry;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;

/// WebRTC 管理器输出的事件。
pub enum WebRtcEvent {
    /// 需经信令转发给对端的本地信令（{sdp:...} 或 {candidate:...}）。
    LocalSignal(Value),
    Connected,
    /// DataChannel 真正 open（可发送）时触发，用于补发首个会话。
    ChannelOpen,
    Text(String),
    Action(String),
    Device(String),
    Log(String),
}

pub struct WebRtcManager {
    events: mpsc::UnboundedSender<WebRtcEvent>,
    pc: Arc<Mutex<Option<Arc<RTCPeerConnection>>>>,
    channel: Arc<Mutex<Option<Arc<RTCDataChannel>>>>,
}

impl WebRtcManager {
    pub fn new(events: mpsc::UnboundedSender<WebRtcEvent>) -> Self {
        WebRtcManager {
            events,
            pc: Arc::new(Mutex::new(None)),
            channel: Arc::new(Mutex::new(None)),
        }
    }

    fn log(&self, s: impl Into<String>) {
        let _ = self.events.send(WebRtcEvent::Log(s.into()));
    }

    /// 创建连接并发起 offer。
    pub async fn create_connection_and_offer(&self) {
        let mut media = MediaEngine::default();
        if media.register_default_codecs().is_err() {
            self.log("注册编解码器失败");
            return;
        }
        let mut registry = Registry::new();
        registry = match register_default_interceptors(registry, &mut media) {
            Ok(r) => r,
            Err(_) => {
                self.log("注册拦截器失败");
                return;
            }
        };
        let api = APIBuilder::new()
            .with_media_engine(media)
            .with_interceptor_registry(registry)
            .build();

        let config = RTCConfiguration {
            ice_servers: vec![RTCIceServer {
                urls: vec!["stun:stun.l.google.com:19302".to_owned()],
                ..Default::default()
            }],
            ..Default::default()
        };

        let pc = match api.new_peer_connection(config).await {
            Ok(pc) => Arc::new(pc),
            Err(_) => {
                self.log("创建 PeerConnection 失败");
                return;
            }
        };

        // ICE candidate → 本地信令。
        let events_ice = self.events.clone();
        pc.on_ice_candidate(Box::new(move |candidate| {
            let events = events_ice.clone();
            Box::pin(async move {
                if let Some(c) = candidate {
                    if let Ok(init) = c.to_json() {
                        let cand = json!({
                            "candidate": init.candidate,
                            "sdpMid": init.sdp_mid.unwrap_or_default(),
                            "sdpMLineIndex": init.sdp_mline_index.unwrap_or(0),
                        });
                        let _ = events.send(WebRtcEvent::LocalSignal(json!({"candidate": cand})));
                    }
                }
            })
        }));

        // ICE 连接状态。
        let events_state = self.events.clone();
        pc.on_ice_connection_state_change(Box::new(move |state: RTCIceConnectionState| {
            let events = events_state.clone();
            Box::pin(async move {
                let _ = events.send(WebRtcEvent::Log(format!("ice state: {}", state)));
                if state == RTCIceConnectionState::Connected
                    || state == RTCIceConnectionState::Completed
                {
                    let _ = events.send(WebRtcEvent::Connected);
                }
            })
        }));

        // HOST 创建 DataChannel "input"。
        let dc = match pc.create_data_channel(wire::msg::CHANNEL_LABEL, None).await {
            Ok(dc) => dc,
            Err(_) => {
                self.log("创建 DataChannel 失败");
                return;
            }
        };
        self.wire_data_channel(&dc);
        *self.channel.lock().await = Some(dc);

        // 创建 offer 并设置本地描述。
        let offer = match pc.create_offer(None).await {
            Ok(o) => o,
            Err(e) => {
                self.log(format!("createOffer 失败: {}", e));
                return;
            }
        };
        if let Err(e) = pc.set_local_description(offer.clone()).await {
            self.log(format!("setLocal 失败: {}", e));
            return;
        }
        let sdp = json!({
            "type": offer.sdp_type.to_string(),
            "sdp": offer.sdp,
        });
        let _ = self.events.send(WebRtcEvent::LocalSignal(json!({"sdp": sdp})));

        *self.pc.lock().await = Some(pc);
    }

    fn wire_data_channel(&self, dc: &Arc<RTCDataChannel>) {
        let events_open = self.events.clone();
        dc.on_open(Box::new(move || {
            let events = events_open.clone();
            Box::pin(async move {
                let _ = events.send(WebRtcEvent::Connected);
                let _ = events.send(WebRtcEvent::ChannelOpen);
            })
        }));

        let events_msg = self.events.clone();
        dc.on_message(Box::new(move |msg: DataChannelMessage| {
            let events = events_msg.clone();
            Box::pin(async move {
                if let Ok(obj) = serde_json::from_slice::<Value>(&msg.data) {
                    match obj.get("type").and_then(|v| v.as_str()) {
                        Some(t) if t == wire::msg::TEXT => {
                            if let Some(text) = obj.get("text").and_then(|v| v.as_str()) {
                                let _ = events.send(WebRtcEvent::Text(text.to_string()));
                            }
                        }
                        Some(t) if t == wire::msg::ACTION => {
                            if let Some(a) = obj.get("action").and_then(|v| v.as_str()) {
                                let _ = events.send(WebRtcEvent::Action(a.to_string()));
                            }
                        }
                        Some(t) if t == wire::msg::HELLO => {
                            if let Some(d) = obj.get("device").and_then(|v| v.as_str()) {
                                let _ = events.send(WebRtcEvent::Device(d.to_string()));
                            }
                        }
                        _ => {}
                    }
                }
            })
        }));
    }

    /// 处理远端信令（answer 或 candidate）。
    pub async fn handle_remote_signal(&self, data: &Value) {
        let pc = { self.pc.lock().await.clone() };
        let pc = match pc {
            Some(pc) => pc,
            None => return,
        };

        if let Some(sdp) = data.get("sdp") {
            let type_str = sdp.get("type").and_then(|v| v.as_str()).unwrap_or("");
            let sdp_str = sdp.get("sdp").and_then(|v| v.as_str()).unwrap_or("");
            let desc = match type_str {
                "answer" => RTCSessionDescription::answer(sdp_str.to_string()),
                "offer" => RTCSessionDescription::offer(sdp_str.to_string()),
                "pranswer" => RTCSessionDescription::pranswer(sdp_str.to_string()),
                _ => RTCSessionDescription::answer(sdp_str.to_string()),
            };
            match desc {
                Ok(d) => {
                    if let Err(e) = pc.set_remote_description(d).await {
                        self.log(format!("setRemote 失败: {}", e));
                    }
                }
                Err(e) => self.log(format!("解析远端 SDP 失败: {}", e)),
            }
        } else if let Some(cand) = data.get("candidate") {
            let candidate = cand.get("candidate").and_then(|v| v.as_str()).unwrap_or("").to_string();
            let sdp_mid = cand.get("sdpMid").and_then(|v| v.as_str()).map(|s| s.to_string());
            let sdp_mline_index = cand
                .get("sdpMLineIndex")
                .and_then(|v| v.as_u64())
                .map(|n| n as u16);
            let init = RTCIceCandidateInit {
                candidate,
                sdp_mid,
                sdp_mline_index,
                username_fragment: None,
            };
            if let Err(e) = pc.add_ice_candidate(init).await {
                self.log(format!("addCandidate 失败: {}", e));
            }
        }
    }

    /// 通过 DataChannel 发送一个 JSON 业务消息。
    pub async fn send_message(&self, obj: &Value) {
        let channel = { self.channel.lock().await.clone() };
        if let Some(channel) = channel {
            let text = obj.to_string();
            let _ = channel.send_text(text).await;
        }
    }

    /// 关闭当前连接与通道。
    pub async fn close(&self) {
        if let Some(channel) = self.channel.lock().await.take() {
            let _ = channel.close().await;
        }
        if let Some(pc) = self.pc.lock().await.take() {
            let _ = pc.close().await;
        }
    }
}
