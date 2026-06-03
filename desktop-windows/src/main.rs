//! Chatput 桌面端（Windows）入口。
//! 纯原生单 exe：tokio 异步运行时跑协调器，Win32 + GDI 跑界面与系统托盘。

// GUI 程序：始终用 windows 子系统，避免启动时弹出黑色控制台窗口。
// 诊断信息走 %APPDATA%\Chatput\crash.log（见 install_panic_log）。
#![windows_subsystem = "windows"]

mod app;
mod core;

use app::app_state::AppState;
use app::coordinator::Coordinator;
use app::settings::AppSettings;

fn main() {
    install_panic_log();

    let settings = AppSettings::load();
    let state = AppState::new();

    // 后台协调器（独立线程 + tokio 运行时）。
    let ui_tx = Coordinator::spawn(state.clone(), settings.clone());

    // 原生 Win32 + GDI 界面（含系统托盘），阻塞运行直到退出。
    app::ui::run(state, ui_tx, settings);
}

/// 将 panic 写入 %APPDATA%\Chatput\crash.log，便于跨会话排查崩溃。
fn install_panic_log() {
    let default = std::panic::take_hook();
    std::panic::set_hook(Box::new(move |info| {
        if let Ok(dir) = std::env::var("APPDATA") {
            let path = std::path::Path::new(&dir).join("Chatput").join("crash.log");
            if let Some(parent) = path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            use std::io::Write;
            if let Ok(mut f) = std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(&path)
            {
                let _ = writeln!(f, "[{:?}] {}", std::time::SystemTime::now(), info);
            }
        }
        default(info);
    }));
}
