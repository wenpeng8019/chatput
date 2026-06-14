//! 全局可观察状态，驱动 UI。线程间通过 Arc<Mutex<..>> 共享。

use crate::core::config;
use crate::core::focus_monitor::FocusSession;
use crate::core::qrcode_gen::QrImage;
use std::collections::VecDeque;
use std::sync::Arc;

/// 状态快照（UI 每帧读取）。
pub struct AppStateInner {
    /// 状态文案的中英文原文，渲染时按当前语言翻译。
    pub status_zh: String,
    pub status_en: String,
    pub connected: bool,
    pub room_code: String,
    /// 当前二维码（RGBA 像素），None 表示无。
    pub qr: Option<Arc<QrImage>>,
    /// 二维码版本号，UI 据此决定是否重建纹理。
    pub qr_version: u64,
    pub sessions: VecDeque<FocusSession>,
    pub log_lines: VecDeque<String>,
    pub server_running: bool,
    pub server_port: u16,
    pub advertised_url: String,
    pub service_active: bool,
    pub connected_device: String,
}

impl Default for AppStateInner {
    fn default() -> Self {
        AppStateInner {
            status_zh: "启动中…".to_string(),
            status_en: "Starting…".to_string(),
            connected: false,
            room_code: String::new(),
            qr: None,
            qr_version: 0,
            sessions: VecDeque::new(),
            log_lines: VecDeque::new(),
            server_running: false,
            server_port: 0,
            advertised_url: String::new(),
            service_active: false,
            connected_device: String::new(),
        }
    }
}

/// 线程安全句柄。
#[derive(Clone)]
pub struct AppState {
    inner: Arc<std::sync::Mutex<AppStateInner>>,
}

impl AppState {
    pub fn new() -> Self {
        AppState {
            inner: Arc::new(std::sync::Mutex::new(AppStateInner::default())),
        }
    }

    pub fn read<R>(&self, f: impl FnOnce(&AppStateInner) -> R) -> R {
        let g = self.inner.lock().unwrap();
        f(&g)
    }

    fn write(&self, f: impl FnOnce(&mut AppStateInner)) {
        let mut g = self.inner.lock().unwrap();
        f(&mut g);
    }

    pub fn set_status(&self, zh: &str, en: &str, connected: bool) {
        self.write(|s| {
            s.status_zh = zh.to_string();
            s.status_en = en.to_string();
            s.connected = connected;
        });
    }

    pub fn set_connected_device(&self, name: &str) {
        self.write(|s| s.connected_device = name.to_string());
    }

    pub fn set_service_active(&self, active: bool) {
        self.write(|s| s.service_active = active);
    }

    pub fn set_server_state(&self, running: bool, port: u16) {
        self.write(|s| {
            s.server_running = running;
            s.server_port = port;
        });
    }

    pub fn set_room(&self, room_code: String, advertised_url: String, qr: Option<QrImage>) {
        self.write(|s| {
            s.room_code = room_code;
            s.advertised_url = advertised_url;
            s.qr = qr.map(Arc::new);
            s.qr_version += 1;
        });
    }

    pub fn clear_room(&self) {
        self.write(|s| {
            s.room_code.clear();
            s.advertised_url.clear();
            s.qr = None;
            s.qr_version += 1;
        });
    }

    pub fn log(&self, line: String) {
        // 同步写入 %APPDATA%\Chatput\runtime.log，便于跨会话/实时排查（E2E 调试）。
        if let Ok(dir) = std::env::var("APPDATA") {
            let path = std::path::Path::new(&dir).join("Chatput").join("runtime.log");
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
                use std::io::Write;
                let _ = writeln!(f, "[{:?}] {}", std::time::SystemTime::now(), line);
            }
        }
        self.write(|s| {
            s.log_lines.push_back(line);
            while s.log_lines.len() > config::limit::LOG_LINES {
                s.log_lines.pop_front();
            }
        });
    }

    pub fn clear_log(&self) {
        self.write(|s| s.log_lines.clear());
    }

    pub fn upsert_session(&self, session: FocusSession) {
        self.write(|s| {
            if let Some(index) = s.sessions.iter().position(|x| x.id == session.id) {
                s.sessions.remove(index);
            }
            s.sessions.push_front(session);
            while s.sessions.len() > config::limit::SESSIONS {
                s.sessions.pop_back();
            }
        });
    }

    pub fn remove_session(&self, id: &str) {
        self.write(|s| s.sessions.retain(|x| x.id != id));
    }
}
