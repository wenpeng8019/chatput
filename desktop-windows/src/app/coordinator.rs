//! 顶层协调器（2.0）：在独立 tokio 运行时中编排信令、WebRTC、
//! 内置服务器、焦点监控、文字注入、远程窗口采集与触控转鼠标。
//! 对标 macOS 的 Coordinator.swift。UI 通过命令通道驱动它，它回写 AppState。

use crate::app::app_state::AppState;
use crate::app::settings::{AppSettings, SignalingMode, TransportMode};
use crate::core::focus_monitor::{FocusEvent, FocusMonitor, FocusSession};
use crate::core::localization::t;
use crate::core::pointer_injector::PointerInjector;
use crate::core::qrcode_gen;
use crate::core::signaling_client::{SignalingClient, SignalingEvent};
use crate::core::signaling_server::{ServerEvent, SignalingServer};
use crate::core::text_injector::{Action, TextInjector};
use crate::core::webrtc_manager::{WebRtcEvent, WebRtcManager};
use crate::core::window_capturer::{CapturerEvent, WindowCapturer};
use crate::core::wire;
use serde_json::{json, Value};
use tokio::sync::mpsc;

/// UI → 协调器命令。
pub enum UiCommand {
    Start,
    Stop,
    ApplyConfig(Box<AppSettings>),
    Quit,
}

pub struct Coordinator {
    state: AppState,
    settings: AppSettings,
    signaling: SignalingClient,
    server: SignalingServer,
    webrtc: WebRtcManager,
    injector: TextInjector,
    focus: FocusMonitor,
    capturer: WindowCapturer,
    pointer: PointerInjector,

    sig_rx: Option<mpsc::UnboundedReceiver<SignalingEvent>>,
    srv_rx: Option<mpsc::UnboundedReceiver<ServerEvent>>,
    rtc_rx: Option<mpsc::UnboundedReceiver<WebRtcEvent>>,
    focus_rx: Option<mpsc::UnboundedReceiver<FocusEvent>>,
    capt_rx: Option<mpsc::UnboundedReceiver<CapturerEvent>>,

    room_id: String,
    token: String,
    transport: TransportMode,
    device_name: String,
    peer_present: bool,

    // 远程窗口画面（2.0）
    screen_session_id: String,
    last_applied_viewport: (i32, i32, i32, i32), // x, y, w, h
    pending_screen_session: Option<(String, i32, i32)>, // (id, vpW, vpH)
    /// 网络变化后是否需要提示重新扫码。
    should_prompt_rescan: bool,

    // 网络变化检测
    last_network_ip: String,
    network_check_counter: u64,
}

impl Coordinator {
    /// 在独立线程内启动 tokio 运行时并运行协调器，返回命令发送端。
    pub fn spawn(state: AppState, settings: AppSettings) -> mpsc::UnboundedSender<UiCommand> {
        let (ui_tx, ui_rx) = mpsc::unbounded_channel::<UiCommand>();

        std::thread::spawn(move || {
            let rt = tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
                .expect("tokio runtime");
            rt.block_on(async move {
                let coordinator = Coordinator::new(state, settings);
                coordinator.run(ui_rx).await;
            });
        });

        ui_tx
    }

    fn new(state: AppState, settings: AppSettings) -> Self {
        let (sig_tx, sig_rx) = mpsc::unbounded_channel::<SignalingEvent>();
        let (srv_tx, srv_rx) = mpsc::unbounded_channel::<ServerEvent>();
        let (rtc_tx, rtc_rx) = mpsc::unbounded_channel::<WebRtcEvent>();

        // 焦点监控用 std mpsc，桥接到 tokio。
        let (focus_tx, focus_rx) = mpsc::unbounded_channel::<FocusEvent>();
        let mut focus = FocusMonitor::new();
        focus.start();
        if let Some(std_rx) = focus.take_receiver() {
            std::thread::spawn(move || {
                while let Ok(ev) = std_rx.recv() {
                    if focus_tx.send(ev).is_err() {
                        break;
                    }
                }
            });
        }

        // 窗口采集器用 std mpsc，桥接到 tokio。
        let (capt_tx, capt_rx) = mpsc::unbounded_channel::<CapturerEvent>();
        let mut capturer = WindowCapturer::new();
        let capt_std_rx = capturer.take_receiver();
        std::thread::spawn(move || {
            while let Ok(ev) = capt_std_rx.recv() {
                if capt_tx.send(ev).is_err() {
                    break;
                }
            }
        });

        let transport = settings.transport;
        Coordinator {
            state,
            settings,
            signaling: SignalingClient::new(sig_tx),
            server: SignalingServer::new(srv_tx),
            webrtc: WebRtcManager::new(rtc_tx),
            injector: TextInjector::new(),
            focus,
            capturer,
            pointer: PointerInjector::new(),
            sig_rx: Some(sig_rx),
            srv_rx: Some(srv_rx),
            rtc_rx: Some(rtc_rx),
            focus_rx: Some(focus_rx),
            capt_rx: Some(capt_rx),
            room_id: String::new(),
            token: String::new(),
            transport,
            device_name: device_name(),
            peer_present: false,
            screen_session_id: String::new(),
            last_applied_viewport: (0, 0, 0, 0),
            pending_screen_session: None,
            should_prompt_rescan: false,
            last_network_ip: String::new(),
            network_check_counter: 0,
        }
    }

    async fn run(mut self, mut ui_rx: mpsc::UnboundedReceiver<UiCommand>) {
        let mut sig_rx = self.sig_rx.take().unwrap();
        let mut srv_rx = self.srv_rx.take().unwrap();
        let mut rtc_rx = self.rtc_rx.take().unwrap();
        let mut focus_rx = self.focus_rx.take().unwrap();
        let mut capt_rx = self.capt_rx.take().unwrap();

        // 默认自动启动服务。
        self.start_service().await;

        loop {
            tokio::select! {
                cmd = ui_rx.recv() => {
                    match cmd {
                        Some(UiCommand::Start) => self.start_service().await,
                        Some(UiCommand::Stop) => self.stop_service().await,
                        Some(UiCommand::ApplyConfig(s)) => self.apply_config(*s).await,
                        Some(UiCommand::Quit) | None => {
                            self.stop_service().await;
                            break;
                        }
                    }
                }
                Some(ev) = sig_rx.recv() => self.on_signaling(ev).await,
                Some(ev) = srv_rx.recv() => self.on_server(ev),
                Some(ev) = rtc_rx.recv() => self.on_webrtc(ev).await,
                Some(ev) = focus_rx.recv() => self.on_focus(ev).await,
                Some(ev) = capt_rx.recv() => self.on_capturer(ev).await,
            }

            // 周期性网络变化检测（每 ~2 秒随事件循环触发）。
            self.network_check_counter += 1;
            if self.network_check_counter % 128 == 0 {
                self.check_network_change();
            }
        }
    }

    // ---- 服务生命周期 ----

    async fn start_service(&mut self) {
        self.transport = self.settings.transport;
        self.state.set_service_active(true);
        self.state
            .set_status("启动中…", "Starting…", false);

        if self.settings.mode == SignalingMode::BuiltIn {
            self.server.start(self.settings.listen_port).await;
        }
        self.bring_up().await;
    }

    async fn stop_service(&mut self) {
        // 保存当前屏幕会话，供重连后自动恢复（对齐 macOS restart()）。
        if !self.screen_session_id.is_empty() {
            let vp_w = self.last_applied_viewport.2.max(1);
            let vp_h = self.last_applied_viewport.3.max(1);
            self.pending_screen_session = Some((self.screen_session_id.clone(), vp_w, vp_h));
            self.state.log(format!(
                "[screen] 保存 pending session: {} ({}x{})",
                self.screen_session_id, vp_w, vp_h
            ));
        }
        self.stop_screen_capture("");
        self.signaling.close().await;
        self.webrtc.close().await;
        self.server.stop().await;
        self.peer_present = false;
        if !self.settings.auto_save_room_id {
            self.settings.saved_room_id = String::new();
            self.settings.saved_token = String::new();
        }
        self.room_id.clear();
        self.token.clear();
        self.state.set_service_active(false);
        self.state.set_server_state(false, 0);
        self.state.clear_room();
        self.state.set_connected_device("");
        self.state.set_status("已停止", "Stopped", false);
    }

    async fn bring_up(&mut self) {
        self.webrtc.close().await;
        self.peer_present = false;
        self.room_id.clear();
        self.token.clear();
        self.state.clear_room();
        let url = self.settings.host_connect_url();
        self.state
            .set_status("连接信令中…", "Connecting…", false);
        self.signaling.connect(url).await;
    }

    async fn apply_config(&mut self, settings: AppSettings) {
        settings.save();
        self.settings = settings;
        self.stop_service().await;
        self.start_service().await;
    }

    // ---- 网络变化监听 ----

    fn check_network_change(&mut self) {
        let current_ip = crate::core::network_info::primary_lan_ipv4().unwrap_or_default();
        if self.last_network_ip.is_empty() {
            self.last_network_ip = current_ip;
            return;
        }
        if current_ip != self.last_network_ip && !current_ip.is_empty() {
            self.state.log(format!(
                "network changed: {} -> {}",
                self.last_network_ip, current_ip
            ));
            self.last_network_ip = current_ip;
            self.should_prompt_rescan = true;
        }
    }

    // ---- 信令事件 ----

    async fn on_signaling(&mut self, ev: SignalingEvent) {
        match ev {
            SignalingEvent::Open => {
                self.state.log(t("信令已连接", "Signaling connected"));
                // 若有保存的房间号，尝试恢复；否则创建新房间。
                if self.settings.auto_save_room_id
                    && !self.settings.saved_room_id.is_empty()
                    && !self.settings.saved_token.is_empty()
                {
                    self.state.set_status("已连接信令，恢复房间…", "Connected, restoring room…", false);
                    self.signaling
                        .send(&json!({
                            wire::key::TYPE: wire::signal::RESTORE_ROOM,
                            "roomId": self.settings.saved_room_id,
                            "token": self.settings.saved_token,
                        }))
                        .await;
                } else {
                    self.state.set_status("已连接信令，创建房间…", "Connected, creating room…", false);
                    self.signaling
                        .send(&json!({ wire::key::TYPE: wire::signal::CREATE_ROOM }))
                        .await;
                }
            }
            SignalingEvent::Message(v) => self.handle_signaling_message(v).await,
            SignalingEvent::Close => {
                self.state
                    .set_status("信令已断开", "Signaling disconnected", false);
                self.state.set_connected_device("");
                // 自动重连。
                let connect_url = self.settings.host_connect_url();
                tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                self.signaling.connect(connect_url).await;
            }
        }
    }

    async fn handle_signaling_message(&mut self, msg: Value) {
        let msg_type = msg.get(wire::key::TYPE).and_then(|v| v.as_str()).unwrap_or("");

        match msg_type {
            t0 if t0 == wire::signal::ROOM_CREATED => {
                self.room_id = msg.get("roomId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                self.token = msg.get("token").and_then(|v| v.as_str()).unwrap_or("").to_string();

                // 持久化房间号。
                if self.settings.auto_save_room_id {
                    self.settings.saved_room_id = self.room_id.clone();
                    self.settings.saved_token = self.token.clone();
                    self.settings.save();
                }

                let advertised_url = self.settings.advertised_url();
                let refreshed = self.should_prompt_rescan;
                self.should_prompt_rescan = false;

                self.state.log(format!("{}: {}", t("二维码地址", "QR URL"), advertised_url));
                if advertised_url.contains("127.0.0.1") {
                    self.state.log(t(
                        "未检测到可用局域网 IP，请在设置 > 内置服务里手动填写电脑的 Wi-Fi/以太网 IPv4。",
                        "No usable LAN IP detected. Set the PC Wi-Fi/Ethernet IPv4 manually in Settings > Built-in.",
                    ));
                }

                let transport_raw = match self.transport {
                    TransportMode::Webrtc => wire::transport::WEBRTC,
                    TransportMode::Websocket => wire::transport::WEBSOCKET,
                };
                let payload = json!({
                    "url": advertised_url,
                    "roomId": self.room_id,
                    "token": self.token,
                    wire::key::TRANSPORT: transport_raw,
                });
                let qr = qrcode_gen::generate(&payload.to_string(), 6, 2);
                self.state
                    .set_room(self.room_id.clone(), advertised_url, qr);
                if refreshed {
                    self.state.set_status("二维码已刷新，请重新扫码", "QR code refreshed, please scan again", false);
                } else {
                    self.state
                        .set_status("等待手机扫码…", "Waiting for phone…", false);
                }
            }

            t0 if t0 == wire::signal::PEER_JOINED => {
                let role = msg.get("role").and_then(|v| v.as_str()).unwrap_or("");
                if role == wire::role::HOST {
                    self.peer_present = true;
                    match self.transport {
                        TransportMode::Webrtc => {
                            self.state
                                .set_status("正在建立连接…", "Negotiating…", false);
                            self.webrtc.create_connection_and_offer().await;
                        }
                        TransportMode::Websocket => {
                            self.state.set_status("已连接", "Connected", true);
                            self.focus.ensure_current_delivered();
                        }
                    }
                }
            }

            t0 if t0 == wire::signal::SIGNAL => {
                if self.transport == TransportMode::Webrtc {
                    if let Some(data) = msg.get(wire::key::DATA) {
                        self.webrtc.handle_remote_signal(data).await;
                    }
                }
            }

            t0 if t0 == wire::signal::MESSAGE => {
                if let Some(data) = msg.get(wire::key::DATA) {
                    self.handle_peer_message(data.clone()).await;
                }
            }

            t0 if t0 == wire::signal::PEER_LEFT => {
                self.state.log(t("手机已断开", "Phone disconnected"));
                self.stop_screen_capture("");
                self.state.set_connected_device("");
                self.webrtc.close().await;
                self.peer_present = false;
                self.state
                    .set_status("手机已断开，等待重连…", "Phone disconnected, waiting to reconnect…", false);
            }

            t0 if t0 == wire::signal::ERROR => {
                let reason = msg.get("reason").and_then(|v| v.as_str()).unwrap_or("error");
                self.state.log(format!("{}: {}", t("信令错误", "Signaling error"), reason));
            }

            _ => {}
        }
    }

    // ---- 内置服务器事件 ----

    fn on_server(&mut self, ev: ServerEvent) {
        match ev {
            ServerEvent::State(running, port) => {
                self.state.set_server_state(running, port);
            }
            ServerEvent::Error(e) => {
                self.state
                    .log(format!("{}: {}", t("服务器错误", "Server error"), e))
            }
            ServerEvent::Log(l) => self.state.log(l),
        }
    }

    // ---- WebRTC 事件 ----

    async fn on_webrtc(&mut self, ev: WebRtcEvent) {
        match ev {
            WebRtcEvent::LocalSignal(data) => {
                self.signaling
                    .send(&json!({ wire::key::TYPE: wire::signal::SIGNAL, wire::key::DATA: data }))
                    .await;
            }
            WebRtcEvent::Connected => {
                self.state.set_status("已连接", "Connected", true);
            }
            WebRtcEvent::ChannelOpen => {
                self.state.set_status("已连接", "Connected", true);
                self.focus.ensure_current_delivered();
                // 断连恢复后重建屏幕采集。
                if let Some((ref sid, vp_w, vp_h)) = self.pending_screen_session.take() {
                    if !sid.is_empty() {
                        self.state.log(format!("[screen] reconnect restore: {}", sid));
                        self.start_screen_capture(sid, vp_w, vp_h);
                    }
                }
            }
            WebRtcEvent::Text(text) => {
                self.injector.inject(&text);
            }
            WebRtcEvent::Action(a) => {
                if let Some(action) = Action::from_raw(&a) {
                    self.injector.perform(action);
                }
            }
            WebRtcEvent::Device(d) => {
                self.state.set_connected_device(&d);
                self.state.log(format!("{}: {}", t("设备", "Device"), d));
            }
            // MARK: 远程窗口画面（2.0）
            WebRtcEvent::ScreenStart(sid, w, h) => {
                self.start_screen_capture(&sid, w, h);
            }
            WebRtcEvent::ScreenStop(sid) => {
                self.stop_screen_capture(&sid);
            }
            WebRtcEvent::Viewport(sid, x, y, w, h) => {
                if sid == self.screen_session_id {
                    self.capturer.set_viewport(x, y, w, h);
                }
            }
            WebRtcEvent::PointerDown(sid, x, y) => {
                if sid == self.screen_session_id {
                    self.pointer.mouse_down(x, y);
                }
            }
            WebRtcEvent::PointerUp(sid, x, y) => {
                if sid == self.screen_session_id {
                    self.pointer.mouse_up(x, y);
                }
            }
            WebRtcEvent::PointerScroll(sid, dx, dy) => {
                if sid == self.screen_session_id {
                    self.pointer.scroll(dx, dy);
                }
            }
            WebRtcEvent::Log(l) => self.state.log(l),
        }
    }

    // ---- 焦点事件 ----

    async fn on_focus(&mut self, ev: FocusEvent) {
        match ev {
            FocusEvent::Session(session) => {
                self.state.upsert_session(session.clone());
                self.send_session(&session).await;
            }
            FocusEvent::SessionClosed(id) => {
                self.state.remove_session(&id);
                self.send_peer_message(&json!({
                    wire::key::TYPE: wire::msg::SESSION_CLOSED,
                    "sessionId": id,
                }))
                .await;
            }
            FocusEvent::SessionInputLost(id) => {
                self.state.log(format!("session input lost: {}", id));
                self.send_peer_message(&json!({
                    wire::key::TYPE: wire::msg::SESSION_INPUT_LOST,
                    "sessionId": id,
                }))
                .await;
            }
        }
    }

    // ---- 窗口采集器事件 ----

    async fn on_capturer(&mut self, ev: CapturerEvent) {
        match ev {
            CapturerEvent::Frame(w, h, data, ts_ns) => {
                self.webrtc
                    .push_video_frame(&data, w as i32, h as i32, ts_ns)
                    .await;
            }
            CapturerEvent::Thumbnail(jpeg) => {
                if !self.screen_session_id.is_empty() {
                    let frame = screen_thumb_frame(&self.screen_session_id, &jpeg);
                    self.webrtc.send_thumb(&frame).await;
                }
            }
            CapturerEvent::Meta(win_w, win_h, vp_x, vp_y, vp_w, vp_h, scale) => {
                if self.screen_session_id.is_empty() {
                    return;
                }
                let applied = (vp_x, vp_y, vp_w, vp_h);
                if applied != self.last_applied_viewport {
                    self.last_applied_viewport = applied;
                    let _ = self.webrtc
                        .send_message(&json!({
                            wire::key::TYPE: wire::msg::SCREEN_META,
                            "sessionId": self.screen_session_id,
                            "win": { "w": win_w, "h": win_h, "scale": scale },
                            "applied": {
                                "x": vp_x, "y": vp_y, "w": vp_w, "h": vp_h,
                            },
                        }))
                        .await;
                }
            }
            CapturerEvent::WindowReady(frame, scale) => {
                // 从采集器的共享状态中获取真实的捕获窗口 HWND。
                let hwnd = self.capturer.capture_hwnd().unwrap_or(
                    windows::Win32::Foundation::HWND(std::ptr::null_mut()),
                );
                self.pointer.update_window(
                    hwnd,
                    frame,
                    ((frame.bottom - frame.top) as f64 / scale) as i32,
                );
            }
            CapturerEvent::Error(msg) => {
                if !self.screen_session_id.is_empty() {
                    self.state.log(format!("[screen] error: {}", msg));
                    let _ = self.webrtc
                        .send_message(&json!({
                            wire::key::TYPE: wire::msg::SCREEN_ERROR,
                            "sessionId": self.screen_session_id,
                            "message": msg,
                        }))
                        .await;
                }
            }
            CapturerEvent::Log(l) => self.state.log(format!("[screen] {}", l)),
        }
    }

    // ---- 远程窗口画面（2.0）----

    fn start_screen_capture(&mut self, session_id: &str, vp_w: i32, vp_h: i32) {
        // 从会话列表查找对应会话。
        let (app, title) = {
            let sessions_snapshot = self.state.read(|s| {
                s.sessions
                    .iter()
                    .find(|sess| sess.id == session_id)
                    .map(|sess| (sess.app.clone(), sess.title.clone()))
            });
            match sessions_snapshot {
                Some(pair) => pair,
                None => {
                    self.state
                        .log(format!("[screen] 未找到会话: {}", session_id));
                    return;
                }
            }
        };

        self.screen_session_id = session_id.to_string();
        self.last_applied_viewport = (0, 0, 0, 0);
        self.state
            .log(format!("[screen] start: {} - {}", app, title));
        self.capturer.start(
            session_id,
            &app,
            &title,
            vp_w.max(1),
            vp_h.max(1),
            self.settings.screen_fps.value(),
        );
    }

    fn stop_screen_capture(&mut self, session_id: &str) {
        if !session_id.is_empty() && session_id != self.screen_session_id {
            return;
        }
        self.state.log("[screen] stop".to_string());
        self.capturer.stop();
        self.screen_session_id.clear();
        self.last_applied_viewport = (0, 0, 0, 0);
    }

    // ---- 会话消息 ----

    async fn send_session(&self, session: &FocusSession) {
        self.send_peer_message(&json!({
            wire::key::TYPE: wire::msg::SESSION,
            "sessionId": session.id,
            "app": session.app,
            "title": session.title,
            "device": self.device_name,
            "ts": session.ts,
        }))
        .await;
    }

    /// 桌面 → 手机。按传输模式选择 DataChannel 或信令中继。
    async fn send_peer_message(&self, obj: &Value) {
        if !self.peer_present {
            return;
        }
        match self.transport {
            TransportMode::Webrtc => self.webrtc.send_message(obj).await,
            TransportMode::Websocket => {
                self.signaling
                    .send(&json!({ wire::key::TYPE: wire::signal::MESSAGE, wire::key::DATA: obj }))
                    .await;
            }
        }
    }

    /// 处理来自手机的业务消息（WebSocket 中继路径）。
    async fn handle_peer_message(&mut self, data: Value) {
        match data.get(wire::key::TYPE).and_then(|v| v.as_str()) {
            Some(t0) if t0 == wire::msg::TEXT => {
                if let Some(text) = data.get("text").and_then(|v| v.as_str()) {
                    self.injector.inject(text);
                }
            }
            Some(t0) if t0 == wire::msg::ACTION => {
                if let Some(a) = data.get("action").and_then(|v| v.as_str()) {
                    if let Some(action) = Action::from_raw(a) {
                        self.injector.perform(action);
                    }
                }
            }
            Some(t0) if t0 == wire::msg::HELLO => {
                if let Some(d) = data.get("device").and_then(|v| v.as_str()) {
                    self.state.set_connected_device(d);
                    self.state.set_status("已连接", "Connected", true);
                }
            }
            _ => {}
        }
    }
}

fn device_name() -> String {
    std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Windows".to_string())
}

/// 缩略图二进制帧：`[2 字节大端 sessionId 长度][sessionId UTF-8][JPEG]`。
fn screen_thumb_frame(session_id: &str, jpeg: &[u8]) -> Vec<u8> {
    let id_bytes = session_id.as_bytes();
    let len = (id_bytes.len() as u16).to_be_bytes();
    let mut data = Vec::with_capacity(2 + id_bytes.len() + jpeg.len());
    data.extend_from_slice(&len);
    data.extend_from_slice(id_bytes);
    data.extend_from_slice(jpeg);
    data
}
