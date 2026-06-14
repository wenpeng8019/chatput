//! 文字注入：把识别文本写入剪贴板，再模拟 Ctrl+V 粘贴到当前焦点输入框，随后还原剪贴板。
//! 操作指令（回车/退格/全选/方向键）直接用 SendInput 模拟按键。

use crate::core::config;
use std::thread;
use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
    VIRTUAL_KEY, VK_A, VK_BACK, VK_CONTROL, VK_DOWN, VK_ESCAPE, VK_LEFT,
    VK_RETURN, VK_RIGHT, VK_SHIFT, VK_UP, VK_V,
};

/// 支持的操作按键，取值与手机端协议一致。
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Action {
    Enter,
    ShiftEnter,
    Backspace,
    SelectAll,
    Clear,
    CursorLeft,
    CursorRight,
    CursorUp,
    CursorDown,
    /// Esc 键（方向模式下退格按钮发送）。
    Escape,
}

impl Action {
    pub fn from_raw(s: &str) -> Option<Action> {
        match s {
            "enter" => Some(Action::Enter),
            "shiftEnter" => Some(Action::ShiftEnter),
            "backspace" => Some(Action::Backspace),
            "selectAll" => Some(Action::SelectAll),
            "clear" => Some(Action::Clear),
            "cursorLeft" => Some(Action::CursorLeft),
            "cursorRight" => Some(Action::CursorRight),
            "cursorUp" => Some(Action::CursorUp),
            "cursorDown" => Some(Action::CursorDown),
            "escape" | "esc" => Some(Action::Escape),
            _ => None,
        }
    }
}

pub struct TextInjector;

impl TextInjector {
    pub fn new() -> Self {
        TextInjector
    }

    /// 把文本写入剪贴板并粘贴，随后异步还原剪贴板。
    pub fn inject(&self, text: &str) {
        if text.is_empty() {
            return;
        }
        let saved = get_clipboard_text();
        if !set_clipboard_text(text) {
            return;
        }
        paste();

        // 粘贴完成后还原剪贴板。
        thread::spawn(move || {
            thread::sleep(config::timing::CLIPBOARD_RESTORE);
            match saved {
                Some(prev) => {
                    let _ = set_clipboard_text(&prev);
                }
                None => {
                    let _ = set_clipboard_text("");
                }
            }
        });
    }

    /// 执行一个操作。
    pub fn perform(&self, action: Action) {
        match action {
            Action::Enter => tap_key(VK_RETURN, &[]),
            Action::ShiftEnter => tap_key(VK_RETURN, &[VK_SHIFT]),
            Action::Backspace => tap_key(VK_BACK, &[]),
            Action::SelectAll => tap_key(VK_A, &[VK_CONTROL]),
            Action::Clear => {
                tap_key(VK_A, &[VK_CONTROL]);
                tap_key(VK_BACK, &[]);
            }
            Action::CursorLeft => tap_key(VK_LEFT, &[]),
            Action::CursorRight => tap_key(VK_RIGHT, &[]),
            Action::CursorUp => self.move_vertically(true),
            Action::CursorDown => self.move_vertically(false),
            Action::Escape => tap_key(VK_ESCAPE, &[]),
        }
    }

    /// 光标上/下移。
    fn move_vertically(&self, up: bool) {
        if up {
            tap_key(VK_UP, &[]);
        } else {
            tap_key(VK_DOWN, &[]);
        }
    }
}

/// 模拟 Ctrl+V 粘贴。
fn paste() {
    tap_key(VK_V, &[VK_CONTROL]);
}

/// 模拟一次按键（按下修饰键 → 按下主键 → 抬起主键 → 抬起修饰键）。
fn tap_key(key: VIRTUAL_KEY, modifiers: &[VIRTUAL_KEY]) {
    let mut inputs: Vec<INPUT> = Vec::with_capacity((modifiers.len() + 1) * 2);

    for m in modifiers {
        inputs.push(key_input(*m, false));
    }
    inputs.push(key_input(key, false));
    inputs.push(key_input(key, true));
    for m in modifiers.iter().rev() {
        inputs.push(key_input(*m, true));
    }

    unsafe {
        SendInput(&inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

fn key_input(key: VIRTUAL_KEY, key_up: bool) -> INPUT {
    let flags = if key_up {
        KEYEVENTF_KEYUP
    } else {
        KEYBD_EVENT_FLAGS(0)
    };
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: key,
                wScan: 0,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

// MARK: - 剪贴板读写（UTF-16）

fn get_clipboard_text() -> Option<String> {
    unsafe {
        if OpenClipboard(HWND::default()).is_err() {
            return None;
        }
        let result = (|| {
            let handle = GetClipboardData(CF_UNICODETEXT.0 as u32).ok()?;
            if handle.0.is_null() {
                return None;
            }
            let hglobal = HGLOBAL(handle.0);
            let ptr = GlobalLock(hglobal) as *const u16;
            if ptr.is_null() {
                return None;
            }
            let mut len = 0usize;
            while *ptr.add(len) != 0 {
                len += 1;
            }
            let slice = std::slice::from_raw_parts(ptr, len);
            let s = String::from_utf16_lossy(slice);
            let _ = GlobalUnlock(hglobal);
            Some(s)
        })();
        let _ = CloseClipboard();
        result
    }
}

fn set_clipboard_text(text: &str) -> bool {
    unsafe {
        if OpenClipboard(HWND::default()).is_err() {
            return false;
        }
        let ok = (|| {
            if EmptyClipboard().is_err() {
                return false;
            }
            // UTF-16 + 结尾 NUL。
            let mut utf16: Vec<u16> = text.encode_utf16().collect();
            utf16.push(0);
            let bytes = utf16.len() * std::mem::size_of::<u16>();

            let hmem = match GlobalAlloc(GMEM_MOVEABLE, bytes) {
                Ok(h) => h,
                Err(_) => return false,
            };
            let dst = GlobalLock(hmem) as *mut u16;
            if dst.is_null() {
                return false;
            }
            std::ptr::copy_nonoverlapping(utf16.as_ptr(), dst, utf16.len());
            let _ = GlobalUnlock(hmem);

            // 所有权移交系统剪贴板。
            if SetClipboardData(CF_UNICODETEXT.0 as u32, HANDLE(hmem.0)).is_err() {
                return false;
            }
            true
        })();
        let _ = CloseClipboard();
        ok
    }
}
