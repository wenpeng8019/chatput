//! 开机自启动管理。写入当前用户的
//! HKCU\Software\Microsoft\Windows\CurrentVersion\Run 注册表项。

use winreg::enums::{HKEY_CURRENT_USER, KEY_READ, KEY_WRITE};
use winreg::RegKey;

const RUN_KEY_PATH: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const VALUE_NAME: &str = "Chatput";

fn exe_path() -> Option<String> {
    std::env::current_exe()
        .ok()
        .and_then(|p| p.to_str().map(|s| s.to_string()))
}

/// 当前是否已启用开机自启。
pub fn is_enabled() -> bool {
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    match hkcu.open_subkey_with_flags(RUN_KEY_PATH, KEY_READ) {
        Ok(key) => key
            .get_value::<String, _>(VALUE_NAME)
            .map(|v| !v.is_empty())
            .unwrap_or(false),
        Err(_) => false,
    }
}

/// 设置开机自启开关。
pub fn set_enabled(enabled: bool) -> bool {
    let hkcu = RegKey::predef(HKEY_CURRENT_USER);
    let key = match hkcu.create_subkey_with_flags(RUN_KEY_PATH, KEY_WRITE) {
        Ok((k, _)) => k,
        Err(_) => return false,
    };
    if enabled {
        match exe_path() {
            Some(exe) => key.set_value(VALUE_NAME, &format!("\"{}\"", exe)).is_ok(),
            None => false,
        }
    } else {
        // 删除不存在的值视为成功。
        match key.delete_value(VALUE_NAME) {
            Ok(_) => true,
            Err(ref e) if e.kind() == std::io::ErrorKind::NotFound => true,
            Err(_) => false,
        }
    }
}
