//! 用户配置，持久化到 %APPDATA%\Chatput\settings.json。

use crate::core::localization::{self, AppLanguage};
use crate::core::network_info;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// 信令服务器运行模式。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum SignalingMode {
    BuiltIn,
    External,
}

impl SignalingMode {
    pub fn raw(self) -> &'static str {
        match self {
            SignalingMode::BuiltIn => "builtIn",
            SignalingMode::External => "external",
        }
    }
    pub fn from_raw(s: &str) -> SignalingMode {
        match s {
            "external" => SignalingMode::External,
            _ => SignalingMode::BuiltIn,
        }
    }
}

/// 手机与桌面之间的业务传输方式。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum TransportMode {
    Webrtc,
    Websocket,
}

impl TransportMode {
    pub fn raw(self) -> &'static str {
        match self {
            TransportMode::Webrtc => "webrtc",
            TransportMode::Websocket => "websocket",
        }
    }
    pub fn from_raw(s: &str) -> TransportMode {
        match s {
            "websocket" => TransportMode::Websocket,
            _ => TransportMode::Webrtc,
        }
    }
    pub fn label(self) -> String {
        match self {
            TransportMode::Webrtc => localization::t("WebRTC P2P", "WebRTC P2P"),
            TransportMode::Websocket => localization::t("WebSocket 中继", "WebSocket Relay"),
        }
    }
    pub fn note(self) -> String {
        match self {
            TransportMode::Webrtc => localization::t(
                "优先直连，延迟更低；在公共 Wi-Fi 下成功率受网络环境影响。",
                "Prefers a direct connection with lower latency; success rate on public Wi-Fi depends on the network.",
            ),
            TransportMode::Websocket => localization::t(
                "所有业务消息走服务器中继；公网与受限网络更稳定。",
                "All traffic is relayed through the server; more stable on public or restricted networks.",
            ),
        }
    }
}

// MARK: - 画面设置（2.0）

/// 远程桌面采集帧率。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ScreenFPS {
    Fps12,
    Fps18,
    Fps24,
    Fps30,
}

impl ScreenFPS {
    pub fn raw(self) -> &'static str {
        match self {
            ScreenFPS::Fps12 => "12",
            ScreenFPS::Fps18 => "18",
            ScreenFPS::Fps24 => "24",
            ScreenFPS::Fps30 => "30",
        }
    }
    pub fn from_raw(s: &str) -> ScreenFPS {
        match s {
            "12" => ScreenFPS::Fps12,
            "24" => ScreenFPS::Fps24,
            "30" => ScreenFPS::Fps30,
            _ => ScreenFPS::Fps18,
        }
    }
    pub fn value(self) -> u32 {
        match self {
            ScreenFPS::Fps12 => 12,
            ScreenFPS::Fps18 => 18,
            ScreenFPS::Fps24 => 24,
            ScreenFPS::Fps30 => 30,
        }
    }
    pub fn label(self) -> String { format!("{} FPS", self.value()) }
}

/// 远程桌面视频编码器。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ScreenCodec {
    H264,
    Vp8,
    Vp9,
}

impl ScreenCodec {
    pub fn raw(self) -> &'static str {
        match self {
            ScreenCodec::H264 => "h264",
            ScreenCodec::Vp8 => "vp8",
            ScreenCodec::Vp9 => "vp9",
        }
    }
    pub fn from_raw(s: &str) -> ScreenCodec {
        match s {
            "vp8" => ScreenCodec::Vp8,
            "vp9" => ScreenCodec::Vp9,
            _ => ScreenCodec::H264,
        }
    }
    pub fn label(self) -> String {
        match self {
            ScreenCodec::H264 => "H.264".to_string(),
            ScreenCodec::Vp8 => "VP8".to_string(),
            ScreenCodec::Vp9 => "VP9".to_string(),
        }
    }
    pub fn note(self) -> String {
        match self {
            ScreenCodec::H264 => localization::t(
                "支持硬编码，延迟最低，屏幕文字最清晰。",
                "Hardware encode supported. Lowest latency, sharpest text.",
            ),
            ScreenCodec::Vp8 => localization::t(
                "软编码，压缩率比 H.264 低约 15–20%，延迟中等。",
                "Software encode. ~15-20% worse compression than H.264, moderate latency.",
            ),
            ScreenCodec::Vp9 => localization::t(
                "软编码，压缩率比 H.264 高约 30%，但编码延迟较高，文字可能发糊。",
                "Software encode. ~30% better compression than H.264, but higher encoding latency. Text may appear soft.",
            ),
        }
    }
}

/// 远程桌面输出分辨率缩放（相对于视口原始尺寸）。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ScreenScale {
    P100,
    P80,
    P75,
    P60,
    P50,
}

impl ScreenScale {
    pub fn raw(self) -> &'static str {
        match self {
            ScreenScale::P100 => "100",
            ScreenScale::P80 => "80",
            ScreenScale::P75 => "75",
            ScreenScale::P60 => "60",
            ScreenScale::P50 => "50",
        }
    }
    pub fn from_raw(s: &str) -> ScreenScale {
        match s {
            "80" => ScreenScale::P80,
            "75" => ScreenScale::P75,
            "60" => ScreenScale::P60,
            "50" => ScreenScale::P50,
            _ => ScreenScale::P100,
        }
    }
    pub fn label(self) -> String { format!("{}%", self.raw()) }
    pub fn factor(self) -> f64 {
        match self {
            ScreenScale::P100 => 1.0,
            ScreenScale::P80 => 0.8,
            ScreenScale::P75 => 0.75,
            ScreenScale::P60 => 0.6,
            ScreenScale::P50 => 0.5,
        }
    }
}

/// 远程桌面画质偏好。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ScreenQuality {
    Disabled,
    MaintainResolution,
    Balanced,
}

impl ScreenQuality {
    pub fn raw(self) -> &'static str {
        match self {
            ScreenQuality::Disabled => "disabled",
            ScreenQuality::MaintainResolution => "maintainResolution",
            ScreenQuality::Balanced => "balanced",
        }
    }
    pub fn from_raw(s: &str) -> ScreenQuality {
        match s {
            "maintainResolution" => ScreenQuality::MaintainResolution,
            "balanced" => ScreenQuality::Balanced,
            _ => ScreenQuality::Disabled,
        }
    }
    pub fn label(self) -> String {
        match self {
            ScreenQuality::Disabled => localization::t("画质优先", "Quality first"),
            ScreenQuality::MaintainResolution => localization::t("保持分辨率", "Keep resolution"),
            ScreenQuality::Balanced => localization::t("平衡", "Balanced"),
        }
    }
}

/// 序列化到磁盘的配置结构。
#[derive(Serialize, Deserialize)]
struct Persisted {
    #[serde(default = "default_mode")]
    mode: String,
    #[serde(default = "default_transport")]
    transport: String,
    #[serde(default = "default_port")]
    listen_port: u16,
    #[serde(default)]
    ip_override: String,
    #[serde(default)]
    external_url: String,
    #[serde(default = "default_language")]
    language: String,
    #[serde(default)]
    launch_at_login: bool,
    // 画面（2.0）
    #[serde(default = "default_fps")]
    screen_fps: String,
    #[serde(default = "default_codec")]
    screen_codec: String,
    #[serde(default = "default_scale")]
    screen_scale: String,
    #[serde(default = "default_quality")]
    screen_quality: String,
    #[serde(default)]
    disable_dynamic_bitrate: bool,
    // 房间复用的持久化
    #[serde(default)]
    auto_save_room_id: bool,
    #[serde(default)]
    saved_room_id: String,
    #[serde(default)]
    saved_token: String,
}

fn default_mode() -> String { "builtIn".to_string() }
fn default_transport() -> String { "webrtc".to_string() }
fn default_port() -> u16 { 8080 }
fn default_language() -> String { "system".to_string() }
fn default_fps() -> String { "18".to_string() }
fn default_codec() -> String { "h264".to_string() }
fn default_scale() -> String { "100".to_string() }
fn default_quality() -> String { "disabled".to_string() }
impl Default for Persisted {
    fn default() -> Self {
        Persisted {
            mode: default_mode(),
            transport: default_transport(),
            listen_port: default_port(),
            ip_override: String::new(),
            external_url: String::new(),
            language: default_language(),
            launch_at_login: false,
            screen_fps: default_fps(),
            screen_codec: default_codec(),
            screen_scale: default_scale(),
            screen_quality: default_quality(),
            disable_dynamic_bitrate: false,
            auto_save_room_id: false,
            saved_room_id: String::new(),
            saved_token: String::new(),
        }
    }
}

/// 运行期配置。
#[derive(Clone)]
pub struct AppSettings {
    pub mode: SignalingMode,
    pub transport: TransportMode,
    pub listen_port: u16,
    pub ip_override: String,
    pub external_url: String,
    pub language: AppLanguage,
    pub launch_at_login: bool,
    // 画面（2.0）
    pub screen_fps: ScreenFPS,
    pub screen_codec: ScreenCodec,
    pub screen_scale: ScreenScale,
    pub screen_quality: ScreenQuality,
    pub disable_dynamic_bitrate: bool,
    // 房间复用
    pub auto_save_room_id: bool,
    pub saved_room_id: String,
    pub saved_token: String,
}

impl AppSettings {
    fn config_path() -> PathBuf {
        let base = std::env::var("APPDATA").unwrap_or_else(|_| ".".to_string());
        let mut p = PathBuf::from(base);
        p.push("Chatput");
        p.push("settings.json");
        p
    }

    /// 从磁盘加载，失败用默认值。
    pub fn load() -> Self {
        let p = Self::config_path();
        let persisted: Persisted = std::fs::read_to_string(&p)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();

        let s = AppSettings {
            mode: SignalingMode::from_raw(&persisted.mode),
            transport: TransportMode::from_raw(&persisted.transport),
            listen_port: if persisted.listen_port == 0 { 8080 } else { persisted.listen_port },
            ip_override: persisted.ip_override,
            external_url: Self::normalize_external_url(&persisted.external_url),
            language: AppLanguage::from_raw(&persisted.language),
            launch_at_login: crate::core::login_item::is_enabled(),
            screen_fps: ScreenFPS::from_raw(&persisted.screen_fps),
            screen_codec: ScreenCodec::from_raw(&persisted.screen_codec),
            screen_scale: ScreenScale::from_raw(&persisted.screen_scale),
            screen_quality: ScreenQuality::from_raw(&persisted.screen_quality),
            disable_dynamic_bitrate: persisted.disable_dynamic_bitrate,
            auto_save_room_id: persisted.auto_save_room_id,
            saved_room_id: persisted.saved_room_id,
            saved_token: persisted.saved_token,
        };
        localization::set_language(s.language);
        s
    }

    /// 持久化到磁盘。
    pub fn save(&self) {
        let persisted = Persisted {
            mode: self.mode.raw().to_string(),
            transport: self.transport.raw().to_string(),
            listen_port: self.listen_port,
            ip_override: self.ip_override.clone(),
            external_url: Self::normalize_external_url(&self.external_url),
            language: self.language.raw().to_string(),
            launch_at_login: self.launch_at_login,
            screen_fps: self.screen_fps.raw().to_string(),
            screen_codec: self.screen_codec.raw().to_string(),
            screen_scale: self.screen_scale.raw().to_string(),
            screen_quality: self.screen_quality.raw().to_string(),
            disable_dynamic_bitrate: self.disable_dynamic_bitrate,
            auto_save_room_id: self.auto_save_room_id,
            saved_room_id: self.saved_room_id.clone(),
            saved_token: self.saved_token.clone(),
        };
        let p = Self::config_path();
        if let Some(dir) = p.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(&persisted) {
            let _ = std::fs::write(&p, json);
        }
        localization::set_language(self.language);
    }

    /// 内置模式下对外广播的 IP（手动覆盖优先，否则自动探测）。
    pub fn advertised_host(&self) -> String {
        let trimmed = self.ip_override.trim();
        if !trimmed.is_empty() {
            return trimmed.to_string();
        }
        network_info::primary_lan_ipv4().unwrap_or_else(|| "127.0.0.1".to_string())
    }

    /// 内置模式下当前可对外广播的主机地址；拿不到局域网地址时返回 None。
    pub fn resolved_advertised_host(&self) -> Option<String> {
        let trimmed = self.ip_override.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
        network_info::primary_lan_ipv4()
    }

    /// 桌面端（host）本地用于连接信令的 URL。
    pub fn host_connect_url(&self) -> String {
        match self.mode {
            SignalingMode::BuiltIn => format!("ws://127.0.0.1:{}", self.listen_port),
            SignalingMode::External => Self::normalize_external_url(&self.external_url),
        }
    }

    /// 写入二维码、供手机连接的 URL。
    pub fn advertised_url(&self) -> String {
        match self.mode {
            SignalingMode::BuiltIn => format!("ws://{}:{}", self.advertised_host(), self.listen_port),
            SignalingMode::External => Self::normalize_external_url(&self.external_url),
        }
    }

    /// 规范化外部地址：补全缺失的 ws:// 前缀；https/http 映射为 wss/ws。
    /// 若为 ws 且未显式端口，默认补 8080。
    pub fn normalize_external_url(raw: &str) -> String {
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            return String::new();
        }
        let lower = trimmed.to_lowercase();
        let normalized: String = if lower.starts_with("ws://") || lower.starts_with("wss://") {
            trimmed.to_string()
        } else if lower.starts_with("https://") {
            format!("wss://{}", &trimmed["https://".len()..])
        } else if lower.starts_with("http://") {
            format!("ws://{}", &trimmed["http://".len()..])
        } else {
            format!("ws://{}", trimmed)
        };

        let lower_n = normalized.to_lowercase();
        if lower_n.starts_with("ws://") {
            let after = &normalized["ws://".len()..];
            let host_part = after.split('/').next().unwrap_or(after);
            if !host_part.contains(':') {
                if let Some(slash_idx) = after.find('/') {
                    return format!("ws://{}:8080{}", &after[..slash_idx], &after[slash_idx..]);
                } else {
                    return format!("ws://{}:8080", after);
                }
            }
        }
        normalized
    }
}
