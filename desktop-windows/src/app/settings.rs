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

/// 序列化到磁盘的配置结构。
#[derive(Serialize, Deserialize)]
struct Persisted {
    mode: String,
    transport: String,
    listen_port: u16,
    ip_override: String,
    external_url: String,
    language: String,
    launch_at_login: bool,
}

impl Default for Persisted {
    fn default() -> Self {
        Persisted {
            mode: "builtIn".to_string(),
            transport: "webrtc".to_string(),
            listen_port: 8080,
            ip_override: String::new(),
            external_url: String::new(),
            language: "system".to_string(),
            launch_at_login: false,
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
            // 以系统实际状态为准。
            launch_at_login: crate::core::login_item::is_enabled(),
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

        // 若为 ws:// 且无端口，补 8080。
        let lower_n = normalized.to_lowercase();
        if lower_n.starts_with("ws://") {
            let after = &normalized["ws://".len()..];
            // host[/path] 部分取到第一个 '/'。
            let host_part = after.split('/').next().unwrap_or(after);
            if !host_part.contains(':') {
                // 在 host 后插入 :8080。
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
