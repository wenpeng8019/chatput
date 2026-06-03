//! 顶层协调器：在独立 tokio 运行时中编排信令、WebRTC、内置服务器、焦点监控与文字注入。
//! 对标 macOS 的 Coordinator.swift。UI 通过命令通道驱动它，它回写 AppState。

use crate::app::app_state::AppState;
use crate::app::settings::{AppSettings, SignalingMode, TransportMode};
use crate::core::focus_monitor::{FocusEvent, FocusMonitor, FocusSession};
use crate::core::localization::t;
use crate::core::qrcode_gen;
use crate::core::signaling_client::{SignalingClient, SignalingEvent};
use crate::core::signaling_server::{ServerEvent, SignalingServer};
use crate::core::text_injector::{Action, TextInjector};
use crate::core::webrtc_manager::{WebRtcEvent, WebRtcManager};
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

    sig_rx: Option<mpsc::UnboundedReceiver<SignalingEvent>>,
    srv_rx: Option<mpsc::UnboundedReceiver<ServerEvent>>,
    rtc_rx: Option<mpsc::UnboundedReceiver<WebRtcEvent>>,
    focus_rx: Option<mpsc::UnboundedReceiver<FocusEvent>>,

    room_id: String,
    token: String,
    transport: TransportMode,
    device_name: String,
    peer_present: bool,
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

        let transport = settings.transport;
        Coordinator {
            state,
            settings,
            signaling: SignalingClient::new(sig_tx),
            server: SignalingServer::new(srv_tx),
            webrtc: WebRtcManager::new(rtc_tx),
            injector: TextInjector::new(),
            focus,
            sig_rx: Some(sig_rx),
            srv_rx: Some(srv_rx),
            rtc_rx: Some(rtc_rx),
            focus_rx: Some(focus_rx),
            room_id: String::new(),
            token: String::new(),
            transport,
            device_name: device_name(),
            peer_present: false,
        }
    }

    async fn run(mut self, mut ui_rx: mpsc::UnboundedReceiver<UiCommand>) {
        let mut sig_rx = self.sig_rx.take().unwrap();
        let mut srv_rx = self.srv_rx.take().unwrap();
        let mut rtc_rx = self.rtc_rx.take().unwrap();
        let mut focus_rx = self.focus_rx.take().unwrap();

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
        self.signaling.close().await;
        self.webrtc.close().await;
        self.server.stop().await;
        self.peer_present = false;
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
        // 重启链路使新配置生效。
        self.stop_service().await;
        self.start_service().await;
    }

    // ---- 信令事件 ----

    async fn on_signaling(&mut self, ev: SignalingEvent) {
        match ev {
            SignalingEvent::Open => {
                self.state.log(t("信令已连接", "Signaling connected"));
                self.signaling
                    .send(&json!({ wire::key::TYPE: wire::signal::CREATE_ROOM }))
                    .await;
            }
            SignalingEvent::Message(v) => self.handle_signaling_message(v).await,
            SignalingEvent::Close => {
                self.state
                    .set_status("信令已断开", "Signaling disconnected", false);
                self.state.set_connected_device("");
            }
        }
    }

    async fn handle_signaling_message(&mut self, msg: Value) {
        let msg_type = msg.get(wire::key::TYPE).and_then(|v| v.as_str()).unwrap_or("");

        match msg_type {
            t0 if t0 == wire::signal::ROOM_CREATED => {
                self.room_id = msg.get("roomId").and_then(|v| v.as_str()).unwrap_or("").to_string();
                self.token = msg.get("token").and_then(|v| v.as_str()).unwrap_or("").to_string();

                let transport_raw = match self.transport {
                    TransportMode::Webrtc => wire::transport::WEBRTC,
                    TransportMode::Websocket => wire::transport::WEBSOCKET,
                };
                let payload = json!({
                    "url": self.settings.advertised_url(),
                    "roomId": self.room_id,
                    "token": self.token,
                    wire::key::TRANSPORT: transport_raw,
                });
                let qr = qrcode_gen::generate(&payload.to_string(), 6, 2);
                self.state
                    .set_room(self.room_id.clone(), self.settings.advertised_url(), qr);
                self.state
                    .set_status("等待手机扫码…", "Waiting for phone…", false);
            }

            t0 if t0 == wire::signal::PEER_JOINED => {
                let role = msg.get("role").and_then(|v| v.as_str()).unwrap_or("");
                // 仅 host 端发起连接。
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
                self.state.set_connected_device("");
                self.webrtc.close().await;
                self.peer_present = false;
                // 重新开房等待再次连接。
                self.bring_up().await;
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
            ServerEvent::Error(e) => self.state.log(format!("{}: {}", t("服务器错误", "Server error"), e)),
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
        }
    }

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

    // ---- 业务消息收发 ----

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
