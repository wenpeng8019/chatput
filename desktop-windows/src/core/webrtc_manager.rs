//! 桌面端 WebRTC HOST（webrtc-rs 2.0）。
//!
//! 创建 PeerConnection 与主 DataChannel "input"（JSON）和缩略图 DataChannel "thumb"（无序二进制），
//! 预协商一条 sendonly 视频轨用于远程窗口画面。
//! 通过 DataChannel 收手机的 text/action/hello/screen-start 等，发 session/viewport/meta 等。
//!
//! 对标 macOS 的 WebRTCManager.swift。

use crate::core::h264_encoder::H264Encoder;
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
use webrtc::media::Sample;
use webrtc::peer_connection::configuration::RTCConfiguration;
use webrtc::peer_connection::sdp::session_description::RTCSessionDescription;
use webrtc::peer_connection::RTCPeerConnection;
use webrtc::rtp_transceiver::rtp_codec::RTCRtpCodecCapability;
use webrtc::rtp_transceiver::rtp_transceiver_direction::RTCRtpTransceiverDirection;
use webrtc::rtp_transceiver::RTCRtpTransceiverInit;
use webrtc::track::track_local::track_local_static_sample::TrackLocalStaticSample;

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
    /// 手机请求开始采集某会话窗口（sessionId, viewport_w, viewport_h）。
    ScreenStart(String, i32, i32),
    /// 手机请求停止采集某会话窗口（sessionId）。
    ScreenStop(String),
    /// 手机拖动视口（sessionId, x, y, w, h）。
    Viewport(String, i32, i32, i32, i32),
    /// 手机 → 桌面：触控转鼠标按下（sessionId, x, y）。
    PointerDown(String, i32, i32),
    /// 手机 → 桌面：触控转鼠标抬起。
    PointerUp(String, i32, i32),
    /// 手机 → 桌面：触控转滚轮（sessionId, dx, dy）。
    PointerScroll(String, i32, i32),
    Log(String),
}

pub struct WebRtcManager {
    events: mpsc::UnboundedSender<WebRtcEvent>,
    pc: Arc<Mutex<Option<Arc<RTCPeerConnection>>>>,
    channel: Arc<Mutex<Option<Arc<RTCDataChannel>>>>,
    thumb_channel: Arc<Mutex<Option<Arc<RTCDataChannel>>>>,
    video_track: Arc<Mutex<Option<Arc<TrackLocalStaticSample>>>>,
    encoder: Arc<Mutex<Option<H264Encoder>>>,
    last_adapt_w: Arc<Mutex<i32>>,
    last_adapt_h: Arc<Mutex<i32>>,
    frame_count: Arc<Mutex<u64>>,
}

impl WebRtcManager {
    pub fn new(events: mpsc::UnboundedSender<WebRtcEvent>) -> Self {
        WebRtcManager {
            events,
            pc: Arc::new(Mutex::new(None)),
            channel: Arc::new(Mutex::new(None)),
            thumb_channel: Arc::new(Mutex::new(None)),
            video_track: Arc::new(Mutex::new(None)),
            encoder: Arc::new(Mutex::new(None)),
            last_adapt_w: Arc::new(Mutex::new(0)),
            last_adapt_h: Arc::new(Mutex::new(0)),
            frame_count: Arc::new(Mutex::new(0)),
        }
    }

    fn log(&self, s: impl Into<String>) {
        let _ = self.events.send(WebRtcEvent::Log(s.into()));
    }

    /// 创建连接并发起 offer（含预协商视频轨）。
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

        // HOST 创建主 DataChannel "input"（有序 JSON）。
        let dc = match pc.create_data_channel(wire::msg::CHANNEL_LABEL, None).await {
            Ok(dc) => dc,
            Err(_) => {
                self.log("创建 DataChannel 失败");
                return;
            }
        };
        self.wire_data_channel(&dc, false);
        *self.channel.lock().await = Some(dc);

        // HOST 创建缩略图 DataChannel "thumb"（无序二进制）。
        let thumb_dc_opts = webrtc::data_channel::data_channel_init::RTCDataChannelInit {
            ordered: Some(false),
            ..Default::default()
        };
        let thumb_dc = match pc
            .create_data_channel(wire::msg::THUMB_CHANNEL, Some(thumb_dc_opts))
            .await
        {
            Ok(dc) => dc,
            Err(_) => {
                self.log("创建缩略图 DataChannel 失败（非致命）");
                return;
            }
        };
        *self.thumb_channel.lock().await = Some(thumb_dc);

        // 预协商一条 sendonly 视频轨（对齐 macOS addTransceiver(with: track, init: sendonly)）。
        let video_track = Arc::new(TrackLocalStaticSample::new(
            RTCRtpCodecCapability {
                mime_type: webrtc::api::media_engine::MIME_TYPE_H264.to_string(),
                ..Default::default()
            },
            "screen0".to_string(),
            "screen".to_string(),
        ));

        let transceiver_init = RTCRtpTransceiverInit {
            direction: RTCRtpTransceiverDirection::Sendonly,
            send_encodings: vec![],
        };
        match pc
            .add_transceiver_from_track(video_track.clone(), Some(transceiver_init))
            .await
        {
            Ok(_) => {
                *self.video_track.lock().await = Some(video_track);
                self.log("视频轨道已挂载到 sendonly transceiver");
            }
            Err(e) => {
                self.log(format!("添加视频 transceiver 失败: {}", e));
            }
        }

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

    fn wire_data_channel(&self, dc: &Arc<RTCDataChannel>, _is_thumb: bool) {
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
                        // MARK: 远程窗口画面（2.0）
                        Some(t) if t == wire::msg::SCREEN_START => {
                            let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                            let vp = obj.get("viewport");
                            let w = vp.and_then(|v| v.get("w")).and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let h = vp.and_then(|v| v.get("h")).and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let _ = events.send(WebRtcEvent::ScreenStart(sid, w, h));
                        }
                        Some(t) if t == wire::msg::SCREEN_STOP => {
                            let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                            let _ = events.send(WebRtcEvent::ScreenStop(sid));
                        }
                        Some(t) if t == wire::msg::VIEWPORT => {
                            let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                            let x = obj.get("x").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let y = obj.get("y").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let w = obj.get("w").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let h = obj.get("h").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let _ = events.send(WebRtcEvent::Viewport(sid, x, y, w, h));
                        }
                        Some(t) if t == wire::msg::POINTER_DOWN => {
                            let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                            let x = obj.get("x").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let y = obj.get("y").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let _ = events.send(WebRtcEvent::PointerDown(sid, x, y));
                        }
                        Some(t) if t == wire::msg::POINTER_UP => {
                            let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                            let x = obj.get("x").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let y = obj.get("y").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let _ = events.send(WebRtcEvent::PointerUp(sid, x, y));
                        }
                        Some(t) if t == wire::msg::POINTER_SCROLL => {
                            let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                            let dx = obj.get("dx").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let dy = obj.get("dy").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                            let _ = events.send(WebRtcEvent::PointerScroll(sid, dx, dy));
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
            let candidate = cand
                .get("candidate")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string();
            let sdp_mid = cand
                .get("sdpMid")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
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

    /// 通过主 DataChannel 发送一个 JSON 业务消息。
    pub async fn send_message(&self, obj: &Value) {
        let channel = { self.channel.lock().await.clone() };
        if let Some(channel) = channel {
            let text = obj.to_string();
            let _ = channel.send_text(text).await;
        }
    }

    /// 经缩略图 DataChannel 发送二进制帧（用于小地图缩略图）。
    pub async fn send_thumb(&self, data: &[u8]) {
        let channel = { self.thumb_channel.lock().await.clone() };
        if let Some(channel) = channel {
            use bytes::Bytes;
            let _ = channel.send(&Bytes::copy_from_slice(data)).await;
        }
    }

    /// 把一帧采集到的窗口子区域画面（BGRA）经 MFT H.264 编码后喂入视频轨。
    pub async fn push_video_frame(&self, bgra: &[u8], w: i32, h: i32, _time_stamp_ns: i64) {
        if w < 2 || h < 2 || bgra.len() < (w * h * 4) as usize {
            return;
        }
        let track = { self.video_track.lock().await.clone() };
        let track = match track {
            Some(t) => t,
            None => {
                let mut fc = self.frame_count.lock().await;
                if *fc == 0 {
                    self.log("push_video_frame: video_track 为 None，视频轨道未就绪");
                }
                *fc += 1;
                return;
            }
        };

        // 按需创建/重建 MFT H.264 编码器。
        {
            let mut enc = self.encoder.lock().await;
            let need_new = match enc.as_ref() {
                Some(e) => e.width() != w as u32 || e.height() != h as u32,
                None => true,
            };
            if need_new {
                match H264Encoder::new(w as u32, h as u32, 18) {
                    Ok(new_enc) => {
                        self.log(format!("H.264 编码器就绪: {}x{}", w, h));
                        *enc = Some(new_enc);
                    }
                    Err(e) => {
                        self.log(format!("H.264 编码器创建失败: {}", e));
                        return;
                    }
                }
            }
        }

        // 编码 BGRA → H.264。
        let h264_data = {
            let mut enc = self.encoder.lock().await;
            match enc.as_mut() {
                Some(e) => match e.encode(bgra) {
                    Ok(data) => data,
                    Err(e) => {
                        self.log(format!("H.264 编码失败: {}", e));
                        return;
                    }
                },
                None => return,
            }
        };

        if h264_data.is_empty() {
            return;
        }

        let sample = Sample {
            data: bytes::Bytes::from(h264_data),
            duration: std::time::Duration::from_secs_f64(1.0 / 18.0),
            ..Default::default()
        };

        if let Err(e) = track.write_sample(&sample).await {
            self.log(format!("write_sample 失败: {}", e));
        }

        // 帧日志。
        let mut last_w = self.last_adapt_w.lock().await;
        let mut last_h = self.last_adapt_h.lock().await;
        let mut fc = self.frame_count.lock().await;
        *fc += 1;
        if w != *last_w || h != *last_h {
            self.log(format!(
                "video frame #{} H.264: {}x{} ({} bytes → {} bytes encoded)",
                *fc, w, h, bgra.len(), sample.data.len()
            ));
            *last_w = w;
            *last_h = h;
        } else if *fc % 30 == 1 {
            self.log(format!(
                "video frame #{} H.264: {}x{} OK ({} bytes encoded)",
                *fc, w, h, sample.data.len()
            ));
        }
    }

    /// 关闭当前连接与通道。
    pub async fn close(&self) {
        if let Some(channel) = self.channel.lock().await.take() {
            let _ = channel.close().await;
        }
        if let Some(thumb) = self.thumb_channel.lock().await.take() {
            let _ = thumb.close().await;
        }
        *self.video_track.lock().await = None;
        *self.encoder.lock().await = None;
        *self.last_adapt_w.lock().await = 0;
        *self.last_adapt_h.lock().await = 0;
        *self.frame_count.lock().await = 0;
        if let Some(pc) = self.pc.lock().await.take() {
            let _ = pc.close().await;
        }
    }
}


