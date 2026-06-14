//! 桌面端 WebRTC HOST（livekit libwebrtc 绑定）。
//!
//! 创建 PeerConnection 与主 DataChannel "input"（JSON）和缩略图 DataChannel "thumb"（无序二进制），
//! 预协商一条 sendonly 视频轨用于远程窗口画面。
//! 通过 DataChannel 收手机的 text/action/hello/screen-start 等，发 session/viewport/meta 等。
//!
//! 视频路径完全对齐 macOS：向 NativeVideoSource 喂原始帧（BGRA→I420），
//! 由 libwebrtc 内部自动编码（H.264）、拥塞控制、PLI→关键帧、带宽估计、码率自适应。
//!
//! 对标 macOS 的 WebRTCManager.swift。

use crate::core::wire;
use serde_json::{json, Value};
use std::str::FromStr;
use std::sync::Arc;
use tokio::sync::mpsc;
use tokio::sync::Mutex;

use libwebrtc::data_channel::{DataBuffer, DataChannel, DataChannelInit, DataChannelState};
use libwebrtc::ice_candidate::IceCandidate;
use libwebrtc::media_stream_track::MediaStreamTrack;
use libwebrtc::native::yuv_helper;
use libwebrtc::peer_connection::{IceConnectionState, OfferOptions, PeerConnection};
use libwebrtc::peer_connection_factory::{
    native::PeerConnectionFactoryExt, ContinualGatheringPolicy, IceServer, IceTransportsType,
    PeerConnectionFactory, RtcConfiguration,
};
use libwebrtc::rtp_transceiver::{RtpTransceiverDirection, RtpTransceiverInit};
use libwebrtc::session_description::{SdpType, SessionDescription};
use libwebrtc::video_frame::{I420Buffer, VideoFrame, VideoRotation};
use libwebrtc::video_source::native::NativeVideoSource;
use libwebrtc::video_source::VideoResolution;
use libwebrtc::video_track::RtcVideoTrack;

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
    factory: Arc<Mutex<Option<PeerConnectionFactory>>>,
    pc: Arc<Mutex<Option<PeerConnection>>>,
    channel: Arc<Mutex<Option<DataChannel>>>,
    thumb_channel: Arc<Mutex<Option<DataChannel>>>,
    video_source: Arc<Mutex<Option<NativeVideoSource>>>,
    video_track: Arc<Mutex<Option<RtcVideoTrack>>>,
    last_w: Arc<Mutex<i32>>,
    last_h: Arc<Mutex<i32>>,
    frame_count: Arc<Mutex<u64>>,
}

impl WebRtcManager {
    pub fn new(events: mpsc::UnboundedSender<WebRtcEvent>) -> Self {
        WebRtcManager {
            events,
            factory: Arc::new(Mutex::new(None)),
            pc: Arc::new(Mutex::new(None)),
            channel: Arc::new(Mutex::new(None)),
            thumb_channel: Arc::new(Mutex::new(None)),
            video_source: Arc::new(Mutex::new(None)),
            video_track: Arc::new(Mutex::new(None)),
            last_w: Arc::new(Mutex::new(0)),
            last_h: Arc::new(Mutex::new(0)),
            frame_count: Arc::new(Mutex::new(0)),
        }
    }

    fn log(&self, s: impl Into<String>) {
        let _ = self.events.send(WebRtcEvent::Log(s.into()));
    }

    /// 创建连接并发起 offer（含预协商视频轨）。
    pub async fn create_connection_and_offer(&self) {
        // PeerConnectionFactory 必须在 Tokio 运行时上下文创建（本方法即在协调器运行时内）。
        let factory = {
            let mut f = self.factory.lock().await;
            if f.is_none() {
                *f = Some(PeerConnectionFactory::default());
            }
            f.as_ref().unwrap().clone()
        };

        let config = RtcConfiguration {
            ice_servers: vec![IceServer {
                urls: vec!["stun:stun.l.google.com:19302".to_owned()],
                username: String::new(),
                password: String::new(),
            }],
            continual_gathering_policy: ContinualGatheringPolicy::GatherContinually,
            ice_transport_type: IceTransportsType::All,
        };

        let pc = match factory.create_peer_connection(config) {
            Ok(pc) => pc,
            Err(e) => {
                self.log(format!("创建 PeerConnection 失败: {:?}", e));
                return;
            }
        };

        // ICE candidate → 本地信令。
        let events_ice = self.events.clone();
        pc.on_ice_candidate(Some(Box::new(move |candidate: IceCandidate| {
            let cand = json!({
                "candidate": candidate.candidate(),
                "sdpMid": candidate.sdp_mid(),
                "sdpMLineIndex": candidate.sdp_mline_index(),
            });
            let _ = events_ice.send(WebRtcEvent::LocalSignal(json!({ "candidate": cand })));
        })));

        // ICE 连接状态。
        let events_state = self.events.clone();
        pc.on_ice_connection_state_change(Some(Box::new(move |state| {
            let _ = events_state.send(WebRtcEvent::Log(format!("ice state: {:?}", state)));
            if state == IceConnectionState::Connected || state == IceConnectionState::Completed {
                let _ = events_state.send(WebRtcEvent::Connected);
            }
        })));

        // HOST 创建主 DataChannel "input"（有序 JSON）。
        let dc = match pc.create_data_channel(
            wire::msg::CHANNEL_LABEL,
            DataChannelInit { ordered: true, ..Default::default() },
        ) {
            Ok(dc) => dc,
            Err(e) => {
                self.log(format!("创建 DataChannel 失败: {:?}", e));
                return;
            }
        };
        self.wire_data_channel(&dc);
        *self.channel.lock().await = Some(dc);

        // HOST 创建缩略图 DataChannel "thumb"（无序二进制）。
        let thumb_dc = match pc.create_data_channel(
            wire::msg::THUMB_CHANNEL,
            DataChannelInit { ordered: false, ..Default::default() },
        ) {
            Ok(dc) => dc,
            Err(e) => {
                self.log(format!("创建缩略图 DataChannel 失败（非致命）: {:?}", e));
                return;
            }
        };
        *self.thumb_channel.lock().await = Some(thumb_dc);

        // 预协商一条 sendonly 视频轨（对齐 macOS addTransceiver(with: track, init: sendonly)）。
        // 向 NativeVideoSource 喂原始帧，libwebrtc 内部自动编码 + 自适应。
        let source = NativeVideoSource::new(
            VideoResolution { width: 1280, height: 720 },
            true, // is_screencast：屏幕内容，启用内容感知编码。
        );
        let track = factory.create_video_track("screen0", source.clone());
        let init = RtpTransceiverInit {
            direction: RtpTransceiverDirection::SendOnly,
            stream_ids: vec!["screen".to_string()],
            send_encodings: vec![],
        };
        match pc.add_transceiver(MediaStreamTrack::from(track.clone()), init) {
            Ok(_) => {
                *self.video_source.lock().await = Some(source);
                *self.video_track.lock().await = Some(track);
                self.log("视频轨道已挂载到 sendonly transceiver");
            }
            Err(e) => {
                self.log(format!("添加视频 transceiver 失败: {:?}", e));
            }
        }

        // 创建 offer 并设置本地描述。
        let offer = match pc.create_offer(OfferOptions::default()).await {
            Ok(o) => o,
            Err(e) => {
                self.log(format!("createOffer 失败: {:?}", e));
                return;
            }
        };
        let sdp_type = offer.sdp_type().to_string();
        let sdp_str = offer.to_string();
        if let Err(e) = pc.set_local_description(offer).await {
            self.log(format!("setLocal 失败: {:?}", e));
            return;
        }
        let sdp = json!({
            "type": sdp_type,
            "sdp": sdp_str,
        });
        let _ = self.events.send(WebRtcEvent::LocalSignal(json!({ "sdp": sdp })));

        *self.pc.lock().await = Some(pc);
    }

    fn wire_data_channel(&self, dc: &DataChannel) {
        // 通道打开 → Connected + ChannelOpen。
        let events_open = self.events.clone();
        dc.on_state_change(Some(Box::new(move |state: DataChannelState| {
            if state == DataChannelState::Open {
                let _ = events_open.send(WebRtcEvent::Connected);
                let _ = events_open.send(WebRtcEvent::ChannelOpen);
            }
        })));

        let events_msg = self.events.clone();
        dc.on_message(Some(Box::new(move |buf: DataBuffer| {
            if let Ok(obj) = serde_json::from_slice::<Value>(buf.data) {
                match obj.get("type").and_then(|v| v.as_str()) {
                    Some(t) if t == wire::msg::TEXT => {
                        if let Some(text) = obj.get("text").and_then(|v| v.as_str()) {
                            let _ = events_msg.send(WebRtcEvent::Text(text.to_string()));
                        }
                    }
                    Some(t) if t == wire::msg::ACTION => {
                        if let Some(a) = obj.get("action").and_then(|v| v.as_str()) {
                            let _ = events_msg.send(WebRtcEvent::Action(a.to_string()));
                        }
                    }
                    Some(t) if t == wire::msg::HELLO => {
                        if let Some(d) = obj.get("device").and_then(|v| v.as_str()) {
                            let _ = events_msg.send(WebRtcEvent::Device(d.to_string()));
                        }
                    }
                    // MARK: 远程窗口画面（2.0）
                    Some(t) if t == wire::msg::SCREEN_START => {
                        let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let vp = obj.get("viewport");
                        let w = vp.and_then(|v| v.get("w")).and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let h = vp.and_then(|v| v.get("h")).and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let _ = events_msg.send(WebRtcEvent::ScreenStart(sid, w, h));
                    }
                    Some(t) if t == wire::msg::SCREEN_STOP => {
                        let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let _ = events_msg.send(WebRtcEvent::ScreenStop(sid));
                    }
                    Some(t) if t == wire::msg::VIEWPORT => {
                        let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let x = obj.get("x").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let y = obj.get("y").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let w = obj.get("w").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let h = obj.get("h").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let _ = events_msg.send(WebRtcEvent::Viewport(sid, x, y, w, h));
                    }
                    Some(t) if t == wire::msg::POINTER_DOWN => {
                        let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let x = obj.get("x").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let y = obj.get("y").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let _ = events_msg.send(WebRtcEvent::PointerDown(sid, x, y));
                    }
                    Some(t) if t == wire::msg::POINTER_UP => {
                        let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let x = obj.get("x").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let y = obj.get("y").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let _ = events_msg.send(WebRtcEvent::PointerUp(sid, x, y));
                    }
                    Some(t) if t == wire::msg::POINTER_SCROLL => {
                        let sid = obj.get("sessionId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                        let dx = obj.get("dx").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let dy = obj.get("dy").and_then(|v| v.as_i64()).unwrap_or(0) as i32;
                        let _ = events_msg.send(WebRtcEvent::PointerScroll(sid, dx, dy));
                    }
                    _ => {}
                }
            }
        })));
    }

    /// 处理远端信令（answer 或 candidate）。
    pub async fn handle_remote_signal(&self, data: &Value) {
        let pc = { self.pc.lock().await.clone() };
        let pc = match pc {
            Some(pc) => pc,
            None => return,
        };

        if let Some(sdp) = data.get("sdp") {
            let type_str = sdp.get("type").and_then(|v| v.as_str()).unwrap_or("answer");
            let sdp_str = sdp.get("sdp").and_then(|v| v.as_str()).unwrap_or("");
            let sdp_type = SdpType::from_str(type_str).unwrap_or(SdpType::Answer);
            match SessionDescription::parse(sdp_str, sdp_type) {
                Ok(desc) => {
                    if let Err(e) = pc.set_remote_description(desc).await {
                        self.log(format!("setRemote 失败: {:?}", e));
                    }
                }
                Err(e) => self.log(format!("解析远端 SDP 失败: {:?}", e)),
            }
        } else if let Some(cand) = data.get("candidate") {
            let candidate = cand.get("candidate").and_then(|v| v.as_str()).unwrap_or("");
            let sdp_mid = cand.get("sdpMid").and_then(|v| v.as_str()).unwrap_or("");
            let sdp_mline_index = cand
                .get("sdpMLineIndex")
                .and_then(|v| v.as_i64())
                .unwrap_or(0) as i32;
            match IceCandidate::parse(sdp_mid, sdp_mline_index, candidate) {
                Ok(ic) => {
                    if let Err(e) = pc.add_ice_candidate(ic).await {
                        self.log(format!("addCandidate 失败: {:?}", e));
                    }
                }
                Err(e) => self.log(format!("解析远端 candidate 失败: {:?}", e)),
            }
        }
    }

    /// 通过主 DataChannel 发送一个 JSON 业务消息。
    pub async fn send_message(&self, obj: &Value) {
        let channel = { self.channel.lock().await.clone() };
        if let Some(channel) = channel {
            let text = obj.to_string();
            let _ = channel.send(text.as_bytes(), false);
        }
    }

    /// 经缩略图 DataChannel 发送二进制帧（用于小地图缩略图）。
    pub async fn send_thumb(&self, data: &[u8]) {
        let channel = { self.thumb_channel.lock().await.clone() };
        if let Some(channel) = channel {
            let _ = channel.send(data, true);
        }
    }

    /// 把一帧采集到的窗口子区域画面（BGRA）转 I420 后喂入 libwebrtc 视频源。
    /// libwebrtc 内部完成 H.264 编码、拥塞控制、PLI→关键帧、码率自适应。
    pub async fn push_video_frame(&self, bgra: &[u8], w: i32, h: i32, time_stamp_ns: i64) {
        if w < 2 || h < 2 || bgra.len() < (w * h * 4) as usize {
            return;
        }
        let source = { self.video_source.lock().await.clone() };
        let source = match source {
            Some(s) => s,
            None => {
                let mut fc = self.frame_count.lock().await;
                if *fc == 0 {
                    self.log("push_video_frame: video_source 为 None，视频轨道未就绪");
                }
                *fc += 1;
                return;
            }
        };

        // BGRA → I420（libyuv，SIMD 加速）。libyuv 的 "ARGB" 即内存 BGRA 字节序，正合 GDI 输出。
        let mut buffer = I420Buffer::new(w as u32, h as u32);
        let (stride_y, stride_u, stride_v) = buffer.strides();
        let (data_y, data_u, data_v) = buffer.data_mut();
        yuv_helper::argb_to_i420(
            bgra,
            (w * 4) as u32,
            data_y,
            stride_y,
            data_u,
            stride_u,
            data_v,
            stride_v,
            w,
            h,
        );

        let frame = VideoFrame {
            rotation: VideoRotation::VideoRotation0,
            timestamp_us: time_stamp_ns / 1000,
            frame_metadata: None,
            buffer,
        };
        source.capture_frame(&frame);

        // 帧日志。
        let mut last_w = self.last_w.lock().await;
        let mut last_h = self.last_h.lock().await;
        let mut fc = self.frame_count.lock().await;
        *fc += 1;
        if w != *last_w || h != *last_h {
            self.log(format!(
                "video frame #{}: {}x{} 已喂入 libwebrtc（{} bytes BGRA → I420）",
                *fc, w, h, bgra.len()
            ));
            *last_w = w;
            *last_h = h;
        } else if *fc % 60 == 1 {
            self.log(format!("video frame #{}: {}x{} OK", *fc, w, h));
        }
    }

    /// 关闭当前连接与通道。
    pub async fn close(&self) {
        if let Some(channel) = self.channel.lock().await.take() {
            channel.close();
        }
        if let Some(thumb) = self.thumb_channel.lock().await.take() {
            thumb.close();
        }
        *self.video_source.lock().await = None;
        *self.video_track.lock().await = None;
        *self.last_w.lock().await = 0;
        *self.last_h.lock().await = 0;
        *self.frame_count.lock().await = 0;
        if let Some(pc) = self.pc.lock().await.take() {
            pc.close();
        }
    }
}
