//! 在采集窗口上模拟鼠标点击与滚轮事件（触控转鼠标 2.0）。
//!
//! 手机发送窗口逻辑坐标，由本类按窗口的屏幕全局位置 + 标题栏高度补偿
//! 换算为屏幕坐标，再通过 SendInput 推入系统事件流。
//!
//! 对标 macOS 的 PointerInjector.swift。

use windows::Win32::Foundation::{HWND, RECT};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    SendInput, INPUT, INPUT_0, INPUT_MOUSE, MOUSEEVENTF_ABSOLUTE, MOUSEEVENTF_LEFTDOWN,
    MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MOVE, MOUSEEVENTF_WHEEL, MOUSEINPUT, MOUSE_EVENT_FLAGS,
};
use windows::Win32::UI::WindowsAndMessaging::{
    GetClientRect, GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN,
};

pub struct PointerInjector {
    /// 窗口在屏幕上的全局位置（左上角坐标系，含标题栏）。
    window_frame: Option<RECT>,
    /// 窗口内容区左上角在屏幕坐标系中的 Y 偏移（标题栏高度补偿后）。
    content_origin_y: i32,
    /// 当前窗口 HWND。
    hwnd: Option<HWND>,
}

impl PointerInjector {
    pub fn new() -> Self {
        PointerInjector {
            window_frame: None,
            content_origin_y: 0,
            hwnd: None,
        }
    }

    /// 更新目标窗口几何信息（每次采集启动时调用）。
    /// `frame` 为 GetWindowRect 返回的全局坐标（含标题栏）。
    pub fn update_window(&mut self, hwnd: HWND, frame: RECT, _content_logical_h: i32) {
        self.hwnd = Some(hwnd);
        self.window_frame = Some(frame);

        // GetWindowRect 返回整个窗口 frame（含标题栏），GetClientRect 返回内容区。
        // 标题栏高度 = frame 高度 - 客户区高度。
        let mut client_rect = RECT::default();
        let client_h = if !hwnd.is_invalid()
            && unsafe { GetClientRect(hwnd, &mut client_rect) }.is_ok()
        {
            client_rect.bottom - client_rect.top
        } else {
            // HWND 无效或无客户区时，假设无标题栏（frame == client）。
            frame.bottom - frame.top
        };
        let frame_h = frame.bottom - frame.top;
        let title_bar_h = (frame_h - client_h).max(0);
        self.content_origin_y = frame.top + title_bar_h;
    }

    /// 窗口逻辑坐标 → 屏幕绝对坐标（补偿标题栏偏移）。
    fn screen_point(&self, x: i32, y: i32) -> Option<(i32, i32)> {
        let frame = self.window_frame?;
        Some((frame.left + x, self.content_origin_y + y))
    }

    /// 鼠标按下（窗口逻辑坐标）。
    pub fn mouse_down(&self, x: i32, y: i32) {
        if let Some((sx, sy)) = self.screen_point(x, y) {
            send_mouse_input(sx, sy, MOUSEEVENTF_LEFTDOWN, 0);
        }
    }

    /// 鼠标抬起（窗口逻辑坐标）。
    pub fn mouse_up(&self, x: i32, y: i32) {
        if let Some((sx, sy)) = self.screen_point(x, y) {
            send_mouse_input(sx, sy, MOUSEEVENTF_LEFTUP, 0);
        }
    }

    /// 滚轮（dy 为像素级滚动量，dx 暂不处理）。
    pub fn scroll(&self, _dx: i32, dy: i32) {
        if let Some((sx, sy)) = self.screen_point(0, 0) {
            if dy != 0 {
                // 先移动鼠标到窗口内再发滚轮（滚轮事件作用于当前鼠标位置）。
                send_mouse_input(sx, sy, MOUSEEVENTF_WHEEL, dy * 120); // WHEEL_DELTA = 120
            }
        }
    }
}

/// 将屏幕绝对坐标归一化到 0..65535 范围，通过 SendInput 发送鼠标事件。
fn send_mouse_input(x: i32, y: i32, flags: MOUSE_EVENT_FLAGS, mouse_data: i32) {
    // 获取虚拟屏幕尺寸（所有显示器联合区域），用于绝对坐标归一化。
    let screen_w = unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) };
    let screen_h = unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) };

    // MOUSEEVENTF_ABSOLUTE 要求坐标归一化到 [0, 65535]。
    // 公式：normalized = (screen_pixel * 65536) / screen_dimension （含 65536 边界）。
    let norm_x = if screen_w > 0 {
        ((x as f64 * 65536.0) / screen_w as f64) as i32
    } else {
        x
    };
    let norm_y = if screen_h > 0 {
        ((y as f64 * 65536.0) / screen_h as f64) as i32
    } else {
        y
    };

    let input = INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT {
                dx: norm_x,
                dy: norm_y,
                mouseData: mouse_data as u32,
                dwFlags: MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE | flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    };

    unsafe {
        SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
    }
}
