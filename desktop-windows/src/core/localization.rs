//! 界面语言与轻量本地化助手。

use std::sync::atomic::{AtomicU8, Ordering};

/// 界面语言。`System` 跟随系统语言，否则强制中文 / 英文。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum AppLanguage {
    System,
    Zh,
    En,
}

impl AppLanguage {
    pub fn raw(self) -> &'static str {
        match self {
            AppLanguage::System => "system",
            AppLanguage::Zh => "zh",
            AppLanguage::En => "en",
        }
    }

    pub fn from_raw(s: &str) -> AppLanguage {
        match s {
            "zh" => AppLanguage::Zh,
            "en" => AppLanguage::En,
            _ => AppLanguage::System,
        }
    }

    /// 在语言选择器里展示的名称。
    pub fn label(self) -> String {
        match self {
            AppLanguage::System => t("跟随系统", "Follow System"),
            AppLanguage::Zh => "中文".to_string(),
            AppLanguage::En => "English".to_string(),
        }
    }
}

// 当前语言全局缓存（0=system, 1=zh, 2=en），供 `t()` 无锁读取。
static CURRENT_LANG: AtomicU8 = AtomicU8::new(0);

/// 设置当前语言（由设置变更时调用）。
pub fn set_language(lang: AppLanguage) {
    let v = match lang {
        AppLanguage::System => 0,
        AppLanguage::Zh => 1,
        AppLanguage::En => 2,
    };
    CURRENT_LANG.store(v, Ordering::Relaxed);
}

/// 当前是否使用中文。
pub fn is_chinese() -> bool {
    match CURRENT_LANG.load(Ordering::Relaxed) {
        1 => true,
        2 => false,
        _ => system_is_chinese(),
    }
}

fn system_is_chinese() -> bool {
    // 读取系统 UI 语言；以 zh 开头则为中文。
    sys_locale_starts_with_zh()
}

#[cfg(target_os = "windows")]
fn sys_locale_starts_with_zh() -> bool {
    use windows::Win32::Globalization::GetUserDefaultLocaleName;
    let mut buf = [0u16; 85];
    let len = unsafe { GetUserDefaultLocaleName(&mut buf) };
    if len <= 0 {
        return false;
    }
    let name = String::from_utf16_lossy(&buf[..(len as usize - 1)]);
    name.to_lowercase().starts_with("zh")
}

#[cfg(not(target_os = "windows"))]
fn sys_locale_starts_with_zh() -> bool {
    false
}

/// 轻量本地化助手：`t("中文", "English")` 按当前语言返回对应文案。
pub fn t(zh: &str, en: &str) -> String {
    if is_chinese() {
        zh.to_string()
    } else {
        en.to_string()
    }
}
