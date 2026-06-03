//! 原生 Win32 + GDI 界面。两类窗口：
//! 1) 主面板 popup —— 无边框，弹在托盘上方（桌面右下），点击窗口外即消失，对齐 macOS NSPopover。
//! 2) 设置窗口 —— 标准带标题栏窗口，使用原生 Tab 控件（通用 / 内置 / 外部 / 日志）。
//!
//! 后台逻辑仍由 Coordinator 驱动。

use crate::app::app_state::AppState;
use crate::app::coordinator::UiCommand;
use crate::app::settings::{AppSettings, SignalingMode, TransportMode};
use crate::core::localization::{self, AppLanguage};
use crate::core::qrcode_gen::QrImage;
use crate::core::{login_item, network_info};
use std::ffi::c_void;
use std::ptr::null_mut;
use std::time::{Duration, Instant};
use tokio::sync::mpsc::UnboundedSender;

use windows::core::{w, PCWSTR};
use windows::Win32::Foundation::{
    COLORREF, ERROR_ALREADY_EXISTS, FALSE, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, TRUE,
    WPARAM,
};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Registry::{
    RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD,
};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::Controls::{
    CloseThemeData, DrawThemeBackground, InitCommonControlsEx, OpenThemeData, HTHEME,
    ICC_TAB_CLASSES, INITCOMMONCONTROLSEX,
};
use windows::Win32::UI::Shell::{
    Shell_NotifyIconW, NIF_ICON, NIF_MESSAGE, NIF_TIP, NIM_ADD, NIM_DELETE, NOTIFYICONDATAW,
};
use windows::Win32::UI::WindowsAndMessaging::*;

// ---- 常量 ----

/// 托盘图标回调消息。
const WM_TRAY: u32 = WM_APP + 1;
/// 语言变更后重建设置控件。
const WM_REBUILD_SETTINGS: u32 = WM_APP + 2;
const TIMER_REPAINT: usize = 1;
const TIMER_LOG: usize = 2;

const POPUP_W: i32 = 300;
const POPUP_H: i32 = 420;
const SET_W: i32 = 500;
const SET_H: i32 = 470;

/// 托盘菜单。
const ID_QUIT: usize = 1004;
const ID_SHOW: usize = 1005;

/// 设置控件 ID。
const ID_CHK_LAUNCH: usize = 2001;
const ID_CB_TRANSPORT: usize = 2002;
const ID_CB_LANGUAGE: usize = 2003;
const ID_ED_PORT: usize = 2004;
const ID_ED_IP: usize = 2005;
const ID_ED_URL: usize = 2006;
const ID_BTN_SAVE_BUILTIN: usize = 2007;
const ID_BTN_SAVE_EXTERNAL: usize = 2008;
const ID_ED_LOG: usize = 2009;
const ID_BTN_CLEAR: usize = 2010;
const ID_TAB: usize = 2100;

// Win32 子控件样式 / 消息（crate 未直接导出的部分）。
const BS_AUTOCHECKBOX: u32 = 0x0003;
const CBS_DROPDOWNLIST: u32 = 0x0003;
const CBS_HASSTRINGS: u32 = 0x0200;
const ES_AUTOHSCROLL: u32 = 0x0080;
const ES_MULTILINE: u32 = 0x0004;
const ES_READONLY: u32 = 0x0800;
const ES_AUTOVSCROLL: u32 = 0x0040;
const SS_LEFT: u32 = 0x0000;
const CB_ADDSTRING: u32 = 0x0143;
const CB_SETCURSEL: u32 = 0x014E;
const CB_GETCURSEL: u32 = 0x0147;
const BM_GETCHECK: u32 = 0x00F0;
const BM_SETCHECK: u32 = 0x00F1;
const CBN_SELCHANGE: u16 = 1;
const BN_CLICKED: u16 = 0;
const EN_CHANGE: u16 = 0x0300;
const WM_CTLCOLOREDIT: u32 = 0x0133;
const WM_CTLCOLORSTATIC: u32 = 0x0138;
const WM_CTLCOLORBTN: u32 = 0x0135;
const WM_SETICON: u32 = 0x0080;
const ICON_SMALL: u32 = 0;
const ICON_BIG: u32 = 1;
/// Tab 主题部件：页面主体填充（与 Tab 页底色一致）。
const TABP_BODY: i32 = 10;
const EM_SETSEL: u32 = 0x00B1;
const EM_SCROLLCARET: u32 = 0x00B7;
const EM_SETCUEBANNER: u32 = 0x1501;

// Tab 控件消息 / 通知。
const TCM_FIRST: u32 = 0x1300;
const TCM_INSERTITEMW: u32 = TCM_FIRST + 62;
const TCM_GETCURSEL: u32 = TCM_FIRST + 11;
const TCN_SELCHANGE: u32 = (0u32).wrapping_sub(551); // TCN_FIRST(-550) - 1
const TCIF_TEXT: u32 = 0x0001;

#[repr(C)]
struct TcItemW {
    mask: u32,
    dw_state: u32,
    dw_state_mask: u32,
    psz_text: *mut u16,
    cch_text_max: i32,
    i_image: i32,
    l_param: isize,
}

#[repr(C)]
struct NmHdr {
    hwnd_from: HWND,
    id_from: usize,
    code: u32,
}

/// popup 自绘按钮。
#[derive(Clone, Copy, PartialEq, Eq)]
enum Btn {
    Start,
    Stop,
    Settings,
    Quit,
}

/// 按钮图标，对齐 macOS SF Symbols（play/stop/gearshape/power）。
#[derive(Clone, Copy)]
enum IconKind {
    Play,
    Stop,
    Gear,
    Power,
}

/// 共享 UI 状态（popup 拥有，设置窗口借用其指针）。
struct UiState {
    state: AppState,
    settings: AppSettings,
    ui_tx: UnboundedSender<UiCommand>,
    hinstance: HINSTANCE,
    popup: HWND,
    settings_win: HWND,
    last_hide: Option<Instant>,
    buttons: Vec<(Btn, RECT)>,
    font_heading: HFONT,
    font_normal: HFONT,
    font_label: HFONT,
    font_small: HFONT,
    font_icon: HFONT,
    font_dot: HFONT,
    tray_icon: HICON,
    app_icon: HICON,
    nid: NOTIFYICONDATAW,
    // 设置控件。
    tab: HWND,
    /// Tab 主题句柄，用于把控件背景填成与 Tab 页一致的底色。
    tab_theme: HTHEME,
    cur_tab: i32,
    tab_ctrls: Vec<(i32, HWND)>,
    /// 需要自定义文字颜色的 STATIC（如模式徽标圆点）。
    colored_statics: Vec<(HWND, COLORREF)>,
    chk_launch: HWND,
    cb_transport: HWND,
    cb_language: HWND,
    ed_port: HWND,
    ed_ip: HWND,
    ed_url: HWND,
    ed_log: HWND,
    btn_save_external: HWND,
}

impl Drop for UiState {
    fn drop(&mut self) {
        unsafe {
            let _ = Shell_NotifyIconW(NIM_DELETE, &self.nid);
            if !self.tray_icon.is_invalid() {
                let _ = DestroyIcon(self.tray_icon);
            }
            if !self.app_icon.is_invalid() {
                let _ = DestroyIcon(self.app_icon);
            }
            let _ = DeleteObject(HGDIOBJ(self.font_heading.0));
            let _ = DeleteObject(HGDIOBJ(self.font_normal.0));
            let _ = DeleteObject(HGDIOBJ(self.font_label.0));
            let _ = DeleteObject(HGDIOBJ(self.font_small.0));
            let _ = DeleteObject(HGDIOBJ(self.font_icon.0));
            let _ = DeleteObject(HGDIOBJ(self.font_dot.0));
        }
    }
}

const POPUP_CLASS: PCWSTR = w!("ChatputPopup");
const SETTINGS_CLASS: PCWSTR = w!("ChatputSettings");

/// 创建 popup 与托盘并运行消息循环。
pub fn run(state: AppState, ui_tx: UnboundedSender<UiCommand>, settings: AppSettings) {
    unsafe {
        // 单实例。
        let _mutex = CreateMutexW(None, TRUE, w!("Global\\ChatputSingletonMutex"));
        if windows::Win32::Foundation::GetLastError() == ERROR_ALREADY_EXISTS {
            if let Ok(existing) = FindWindowW(POPUP_CLASS, None) {
                let _ = ShowWindow(existing, SW_SHOW);
                let _ = SetForegroundWindow(existing);
            }
            return;
        }

        let hmodule = GetModuleHandleW(None).expect("module handle");
        let hinstance = HINSTANCE(hmodule.0);

        let icc = INITCOMMONCONTROLSEX {
            dwSize: std::mem::size_of::<INITCOMMONCONTROLSEX>() as u32,
            dwICC: ICC_TAB_CLASSES,
        };
        let _ = InitCommonControlsEx(&icc);

        // popup 窗口类（CS_DROPSHADOW 让无边框弹窗带系统投影，对齐 NSPopover）。
        let popup_wc = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW | CS_DROPSHADOW,
            lpfnWndProc: Some(popup_wndproc),
            hInstance: hinstance,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            lpszClassName: POPUP_CLASS,
            ..Default::default()
        };
        RegisterClassW(&popup_wc);

        // 设置窗口类（标准对话框灰底）。
        let set_wc = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(settings_wndproc),
            hInstance: hinstance,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH((COLOR_WINDOW.0 + 1) as isize as *mut c_void),
            lpszClassName: SETTINGS_CLASS,
            ..Default::default()
        };
        RegisterClassW(&set_wc);

        let st = Box::new(UiState {
            state,
            settings,
            ui_tx,
            hinstance,
            popup: HWND(null_mut()),
            settings_win: HWND(null_mut()),
            last_hide: None,
            buttons: Vec::new(),
            font_heading: make_font(-17, 700),
            font_normal: make_font(-15, 400),
            font_label: make_font(-13, 400),
            font_small: make_font(-12, 400),
            font_icon: make_icon_font(-15),
            font_dot: make_icon_font(-11),
            tray_icon: create_tray_icon(),
            app_icon: create_app_icon(256),
            nid: NOTIFYICONDATAW::default(),
            tab: HWND(null_mut()),
            tab_theme: HTHEME::default(),
            cur_tab: 0,
            tab_ctrls: Vec::new(),
            colored_statics: Vec::new(),
            chk_launch: HWND(null_mut()),
            cb_transport: HWND(null_mut()),
            cb_language: HWND(null_mut()),
            ed_port: HWND(null_mut()),
            ed_ip: HWND(null_mut()),
            ed_url: HWND(null_mut()),
            ed_log: HWND(null_mut()),
            btn_save_external: HWND(null_mut()),
        });
        let ptr = Box::into_raw(st);

        let style = WINDOW_STYLE(WS_POPUP.0);
        let popup = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            POPUP_CLASS,
            w!("Chatput"),
            style,
            0,
            0,
            POPUP_W,
            POPUP_H,
            None,
            None,
            hinstance,
            Some(ptr as *const c_void),
        )
        .expect("create popup");

        position_popup(popup);
        let _ = ShowWindow(popup, SW_SHOW);
        let _ = SetForegroundWindow(popup);

        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).0 > 0 {
            // 设置窗口的键盘导航（Tab 切换等）。
            let sw = state_ptr(popup).map(|s| s.settings_win).unwrap_or(HWND(null_mut()));
            if !sw.is_invalid() && IsDialogMessageW(sw, &msg).as_bool() {
                continue;
            }
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
    }
}

unsafe fn state_ptr<'a>(hwnd: HWND) -> Option<&'a mut UiState> {
    let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut UiState;
    if ptr.is_null() {
        None
    } else {
        Some(&mut *ptr)
    }
}

// ---- popup 窗口过程 ----

unsafe extern "system" fn popup_wndproc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_NCCREATE => {
            let cs = lparam.0 as *const CREATESTRUCTW;
            let ptr = (*cs).lpCreateParams as *mut UiState;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, ptr as isize);
            if !ptr.is_null() {
                (*ptr).popup = hwnd;
            }
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_CREATE => {
            if let Some(st) = state_ptr(hwnd) {
                add_tray(st);
                SetTimer(hwnd, TIMER_REPAINT, 250, None);
            }
            LRESULT(0)
        }
        // 点窗口外 → 失活 → 隐藏（对齐 NSPopover transient）。
        WM_ACTIVATE => {
            if (wparam.0 & 0xffff) as u16 == 0 {
                if let Some(st) = state_ptr(hwnd) {
                    st.last_hide = Some(Instant::now());
                }
                let _ = ShowWindow(hwnd, SW_HIDE);
            }
            LRESULT(0)
        }
        WM_ERASEBKGND => LRESULT(1),
        WM_PAINT => {
            if let Some(st) = state_ptr(hwnd) {
                paint_popup(st);
            }
            LRESULT(0)
        }
        WM_TIMER => {
            if IsWindowVisible(hwnd).as_bool() {
                let _ = InvalidateRect(hwnd, None, FALSE);
            }
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            if let Some(st) = state_ptr(hwnd) {
                let x = (lparam.0 & 0xffff) as i16 as i32;
                let y = ((lparam.0 >> 16) & 0xffff) as i16 as i32;
                let hit = st
                    .buttons
                    .iter()
                    .find(|(_, r)| x >= r.left && x < r.right && y >= r.top && y < r.bottom)
                    .map(|(b, _)| *b);
                if let Some(b) = hit {
                    handle_button(st, b);
                }
            }
            LRESULT(0)
        }
        WM_TRAY => {
            if let Some(st) = state_ptr(hwnd) {
                let ev = (lparam.0 as u32) & 0xffff;
                if ev == WM_LBUTTONUP {
                    toggle_popup(st);
                } else if ev == WM_RBUTTONUP || ev == WM_CONTEXTMENU {
                    show_tray_menu(st);
                }
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            let cmd = wparam.0 & 0xffff;
            if cmd == ID_QUIT {
                if let Some(st) = state_ptr(hwnd) {
                    let _ = st.ui_tx.send(UiCommand::Quit);
                }
                let _ = DestroyWindow(hwnd);
            } else if cmd == ID_SHOW {
                if let Some(st) = state_ptr(hwnd) {
                    if !IsWindowVisible(st.popup).as_bool() {
                        position_popup(st.popup);
                        let _ = ShowWindow(st.popup, SW_SHOW);
                    }
                    let _ = SetForegroundWindow(st.popup);
                    let _ = InvalidateRect(st.popup, None, FALSE);
                }
            }
            LRESULT(0)
        }
        WM_DESTROY => {
            PostQuitMessage(0);
            LRESULT(0)
        }
        WM_NCDESTROY => {
            let ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA) as *mut UiState;
            if !ptr.is_null() {
                drop(Box::from_raw(ptr));
                SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

/// 定位到托盘上方（工作区右下角）。
unsafe fn position_popup(hwnd: HWND) {
    let mut wa = RECT::default();
    let _ = SystemParametersInfoW(
        SPI_GETWORKAREA,
        0,
        Some(&mut wa as *mut RECT as *mut c_void),
        SYSTEM_PARAMETERS_INFO_UPDATE_FLAGS(0),
    );
    let x = (wa.right - POPUP_W - 8).max(wa.left + 8);
    let y = (wa.bottom - POPUP_H - 8).max(wa.top + 8);
    let _ = SetWindowPos(hwnd, HWND_TOPMOST, x, y, POPUP_W, POPUP_H, SWP_NOACTIVATE);
}

unsafe fn toggle_popup(st: &mut UiState) {
    if IsWindowVisible(st.popup).as_bool() {
        let _ = ShowWindow(st.popup, SW_HIDE);
        return;
    }
    // 刚因失活隐藏的瞬间再次点击托盘 → 视为收起。
    if let Some(t) = st.last_hide {
        if t.elapsed() < Duration::from_millis(250) {
            return;
        }
    }
    position_popup(st.popup);
    let _ = ShowWindow(st.popup, SW_SHOW);
    let _ = SetForegroundWindow(st.popup);
    let _ = InvalidateRect(st.popup, None, FALSE);
}

unsafe fn handle_button(st: &mut UiState, btn: Btn) {
    match btn {
        Btn::Start => {
            let _ = st.ui_tx.send(UiCommand::Start);
        }
        Btn::Stop => {
            let _ = st.ui_tx.send(UiCommand::Stop);
        }
        Btn::Settings => {
            open_settings(st);
            return;
        }
        Btn::Quit => {
            let _ = st.ui_tx.send(UiCommand::Quit);
            let _ = DestroyWindow(st.popup);
            return;
        }
    }
    let _ = InvalidateRect(st.popup, None, FALSE);
}

// ---- 托盘 ----

unsafe fn add_tray(st: &mut UiState) {
    let mut nid = NOTIFYICONDATAW {
        cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
        hWnd: st.popup,
        uID: 1,
        uFlags: NIF_ICON | NIF_MESSAGE | NIF_TIP,
        uCallbackMessage: WM_TRAY,
        hIcon: st.tray_icon,
        ..Default::default()
    };
    let tip: Vec<u16> = localization::t("聊入", "Chatput")
        .encode_utf16()
        .chain(std::iter::once(0))
        .collect();
    for (i, c) in tip.iter().take(nid.szTip.len() - 1).enumerate() {
        nid.szTip[i] = *c;
    }
    let _ = Shell_NotifyIconW(NIM_ADD, &nid);
    st.nid = nid;
}

unsafe fn refresh_tray(st: &mut UiState) {
    let _ = Shell_NotifyIconW(NIM_DELETE, &st.nid);
    add_tray(st);
}

unsafe fn show_tray_menu(st: &UiState) {
    let menu = match CreatePopupMenu() {
        Ok(m) => m,
        Err(_) => return,
    };
    let show = to_wide(&localization::t("显示", "Show"));
    let _ = AppendMenuW(menu, MF_STRING, ID_SHOW, PCWSTR(show.as_ptr()));
    let _ = AppendMenuW(menu, MF_SEPARATOR, 0, PCWSTR::null());
    let quit = to_wide(&localization::t("退出", "Quit"));
    let _ = AppendMenuW(menu, MF_STRING, ID_QUIT, PCWSTR(quit.as_ptr()));
    // 左键默认行为对应「显示」。
    let _ = SetMenuDefaultItem(menu, ID_SHOW as u32, FALSE.0 as u32);

    let mut pt = POINT::default();
    let _ = GetCursorPos(&mut pt);
    let _ = SetForegroundWindow(st.popup);
    let _ = TrackPopupMenu(menu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, st.popup, None);
    let _ = DestroyMenu(menu);
}

/// 任务栏是否为浅色主题（决定托盘图标用深色还是浅色，保证可见且与系统一致）。
unsafe fn taskbar_is_light() -> bool {
    let mut val: u32 = 1;
    let mut sz = std::mem::size_of::<u32>() as u32;
    let r = RegGetValueW(
        HKEY_CURRENT_USER,
        w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        w!("SystemUsesLightTheme"),
        RRF_RT_REG_DWORD,
        None,
        Some(&mut val as *mut u32 as *mut c_void),
        Some(&mut sz),
    );
    if r.is_ok() {
        val != 0
    } else {
        true
    }
}

/// 按 chatput-menubar.win.svg 的几何绘制图形到 DC。
/// 这里直接沿用 macOS chatput-menubar.svg 的原始坐标，并把 viewBox 3.5..32.5 映射到 32×32，
/// 避免运行时图标与 SVG 母版变成两套设计。
unsafe fn paint_tray_shape(dc: HDC, s: f32, color: COLORREF) {
    let q = |v: f32| ((v - 3.5) * (32.0 / 29.0) * s).round() as i32;
    let l = |v: f32| (v * (32.0 / 29.0) * s).round() as i32;
    let brush = CreateSolidBrush(color);

    // 气泡轮廓环 = 外形 − 内腔。坐标来自 chatput-menubar.svg。
    let outer = CreateRoundRectRgn(q(5.0), q(5.0), q(31.0), q(25.0), l(8.0), l(8.0));
    let outer_tail = [
        POINT { x: q(19.0), y: q(25.0) },
        POINT { x: q(13.0), y: q(31.0) },
        POINT { x: q(13.0), y: q(25.0) },
    ];
    let outer_tail_rgn = CreatePolygonRgn(&outer_tail, WINDING);
    CombineRgn(outer, outer, outer_tail_rgn, RGN_OR);
    let _ = DeleteObject(HGDIOBJ(outer_tail_rgn.0));

    let inner = CreateRoundRectRgn(q(7.5), q(7.5), q(28.5), q(22.5), l(3.0), l(3.0));
    let inner_tail = [
        POINT { x: q(19.4), y: q(22.5) },
        POINT { x: q(15.5), y: q(26.5) },
        POINT { x: q(15.5), y: q(22.5) },
    ];
    let inner_tail_rgn = CreatePolygonRgn(&inner_tail, WINDING);
    CombineRgn(inner, inner, inner_tail_rgn, RGN_OR);
    let _ = DeleteObject(HGDIOBJ(inner_tail_rgn.0));

    let shape = CreateRectRgn(0, 0, 0, 0);
    CombineRgn(shape, outer, inner, RGN_DIFF);
    let _ = DeleteObject(HGDIOBJ(outer.0));
    let _ = DeleteObject(HGDIOBJ(inner.0));

    // 键盘按键：两排各四点。
    let r = 1.05_f32;
    for cy in [12.0_f32, 15.0] {
        for cx in [12.0_f32, 16.0, 20.0, 24.0] {
            let dot = CreateEllipticRgn(q(cx - r), q(cy - r), q(cx + r), q(cy + r));
            CombineRgn(shape, shape, dot, RGN_OR);
            let _ = DeleteObject(HGDIOBJ(dot.0));
        }
    }
    // 空格键。
    let spc = CreateRoundRectRgn(q(13.0), q(17.8), q(23.0), q(19.7), q(1.9), q(1.9));
    CombineRgn(shape, shape, spc, RGN_OR);
    let _ = DeleteObject(HGDIOBJ(spc.0));

    let _ = FillRgn(dc, shape, brush);
    let _ = DeleteObject(HGDIOBJ(shape.0));
    let _ = DeleteObject(HGDIOBJ(brush.0));
}

/// 托盘图标：按 chatput-menubar.win.svg 渲染。8× 超采样 + HALFTONE 缩小得到抗锯齿，
/// 生成带 alpha 的 32 位图标；单色随任务栏主题取深/浅色，铺满画布。
unsafe fn create_tray_icon() -> HICON {
    let sz = GetSystemMetrics(SM_CXSMICON).max(16);
    let big = sz * 8;
    let screen = GetDC(None);

    // 前景色（浅色任务栏近黑 / 深色任务栏近白）。背景保持真正透明。
    let (fr, fg_, fb): (u32, u32, u32) = if taskbar_is_light() {
        (0x2B, 0x2B, 0x2B)
    } else {
        (0xF2, 0xF2, 0xF2)
    };

    // 1) 大画布渲染：黑底 + 白色图形。
    let bigdc = CreateCompatibleDC(screen);
    let bigbmp = CreateCompatibleBitmap(screen, big, big);
    let oldbig = SelectObject(bigdc, HGDIOBJ(bigbmp.0));
    let black = CreateSolidBrush(COLORREF(0));
    let fullbig = RECT { left: 0, top: 0, right: big, bottom: big };
    FillRect(bigdc, &fullbig, black);
    let _ = DeleteObject(HGDIOBJ(black.0));
    paint_tray_shape(bigdc, big as f32 / 32.0, COLORREF(0x00FFFFFF));

    // 2) 目标 32 位 DIB（可直接读写像素）。
    let mut bits: *mut c_void = null_mut();
    let bi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: sz,
            biHeight: -sz, // 自上而下
            biPlanes: 1,
            biBitCount: 32,
            biCompression: BI_RGB.0,
            ..Default::default()
        },
        ..Default::default()
    };
    let dstbmp =
        CreateDIBSection(screen, &bi, DIB_RGB_COLORS, &mut bits, None, 0).unwrap_or_default();
    let dstdc = CreateCompatibleDC(screen);
    let olddst = SelectObject(dstdc, HGDIOBJ(dstbmp.0));
    SetStretchBltMode(dstdc, HALFTONE);
    let _ = SetBrushOrgEx(dstdc, 0, 0, None);
    let _ = StretchBlt(dstdc, 0, 0, sz, sz, bigdc, 0, 0, big, big, SRCCOPY);
    let _ = GdiFlush();

    let stride = (((sz + 15) / 16) * 2) as usize;
    let mut mask_bits = vec![0xffu8; stride * sz as usize]; // 1=透明；图形像素改成 0=不透明

    // 3) 覆盖率（缩小后的灰度）→ 预乘 ARGB；同时生成像素级 AND mask。
    // 双保险：新托盘走 alpha，旧路径走 mask，背景都保持透明。
    if !bits.is_null() {
        let px = bits as *mut u32;
        for y in 0..sz {
            for x in 0..sz {
                let i = (y * sz + x) as isize;
                let v = *px.offset(i);
            let a = v & 0xff; // 白图缩小后任一通道即覆盖率
                let r = (fr * a) / 255;
                let g = (fg_ * a) / 255;
                let b = (fb * a) / 255;
                *px.offset(i) = (a << 24) | (r << 16) | (g << 8) | b;

                if a > 12 {
                    let row = (sz - 1 - y) as usize; // 1bpp DDB bits are bottom-up.
                    let byte = row * stride + (x as usize / 8);
                    let bit = 7 - (x as usize % 8);
                    mask_bits[byte] &= !(1u8 << bit);
                }
            }
        }
    }

    SelectObject(dstdc, olddst);
    let _ = DeleteDC(dstdc);
    SelectObject(bigdc, oldbig);
    let _ = DeleteObject(HGDIOBJ(bigbmp.0));
    let _ = DeleteDC(bigdc);
    ReleaseDC(None, screen);

    // AND mask：1=透明，0=不透明，和 alpha 覆盖率对应。
    let mask = CreateBitmap(sz, sz, 1, 1, Some(mask_bits.as_ptr() as *const c_void));
    let ii = ICONINFO {
        fIcon: TRUE,
        xHotspot: 0,
        yHotspot: 0,
        hbmMask: mask,
        hbmColor: dstbmp,
    };
    let icon = CreateIconIndirect(&ii).unwrap_or_default();
    let _ = DeleteObject(HGDIOBJ(mask.0));
    let _ = DeleteObject(HGDIOBJ(dstbmp.0));
    icon
}

/// 应用图标：对齐 chatput-desktop.svg——浅色 squircle 背景 +
/// 蓝色聊天气泡（后）+ 蓝色键盘面板与白键（前），整体水平镜像。
unsafe fn create_app_icon(sz: i32) -> HICON {
    let screen = GetDC(None);
    let full = RECT { left: 0, top: 0, right: sz, bottom: sz };
    let f = sz as f32 / 1024.0;
    let s = |v: f32| (v * f).round() as i32; // 缩放
    let mx = |v: f32| sz - (v * f).round() as i32; // 水平镜像后的 x
    const BLUE: COLORREF = COLORREF(0x00FF950A); // #0A95FF（COLORREF 为 BGR）
    let r = s(229.0) * 2; // squircle 圆角直径

    let cdc = CreateCompatibleDC(screen);
    let color = CreateCompatibleBitmap(screen, sz, sz);
    let cold = SelectObject(cdc, HGDIOBJ(color.0));
    // 圆角外先填黑（掩码透明区）。
    let blackbg = CreateSolidBrush(COLORREF(0));
    FillRect(cdc, &full, blackbg);
    let _ = DeleteObject(HGDIOBJ(blackbg.0));

    let npen = CreatePen(PS_NULL, 0, COLORREF(0));
    let oldpen = SelectObject(cdc, HGDIOBJ(npen.0));

    let fill = |dc: HDC, c: COLORREF, draw: &dyn Fn(HDC)| {
        let b = CreateSolidBrush(c);
        let ob = SelectObject(dc, HGDIOBJ(b.0));
        draw(dc);
        SelectObject(dc, ob);
        let _ = DeleteObject(HGDIOBJ(b.0));
    };

    // 背景 squircle（浅灰白）。
    fill(cdc, COLORREF(0x00F5F1EE), &|dc| {
        let _ = RoundRect(dc, 0, 0, sz, sz, r, r);
    });

    // 后层：聊天气泡（圆角矩形主体 + 朝下尾巴），镜像。
    fill(cdc, BLUE, &|dc| {
        let _ = RoundRect(dc, mx(575.0), s(417.0), mx(163.0), s(753.0), s(200.0), s(200.0));
        let tail = [
            POINT { x: mx(373.0), y: s(753.0) },
            POINT { x: mx(277.0), y: s(829.0) },
            POINT { x: mx(277.0), y: s(753.0) },
        ];
        let _ = Polygon(dc, &tail);
    });

    // 前层：键盘面板——先白色护城河（描边），再蓝色面板。
    let m = s(40.0); // 护城河宽
    fill(cdc, COLORREF(0x00F5F1EE), &|dc| {
        let _ = RoundRect(dc, mx(861.0) - m, s(195.0) - m, mx(381.0) + m, s(495.0) + m, s(200.0), s(200.0));
    });
    fill(cdc, BLUE, &|dc| {
        let _ = RoundRect(dc, mx(861.0), s(195.0), mx(381.0), s(495.0), s(120.0), s(120.0));
    });

    // 白键：两排各 6 点 + 空格键。
    fill(cdc, COLORREF(0x00FFFFFF), &|dc| {
        let rr = s(20.0).max(1);
        for row in [78.0_f32, 148.0] {
            for col in [74.0_f32, 142.0, 210.0, 278.0, 346.0, 414.0] {
                let cx = mx(381.0 + col);
                let cy = s(195.0 + row);
                let _ = Ellipse(dc, cx - rr, cy - rr, cx + rr, cy + rr);
            }
        }
        let _ = RoundRect(
            dc,
            mx(381.0 + 350.0),
            s(195.0 + 216.0),
            mx(381.0 + 130.0),
            s(195.0 + 252.0),
            s(36.0),
            s(36.0),
        );
    });

    SelectObject(cdc, oldpen);
    let _ = DeleteObject(HGDIOBJ(npen.0));
    SelectObject(cdc, cold);
    let _ = DeleteDC(cdc);

    // 掩码：圆角方形内 0（不透明），外 1（透明）。
    let mdc = CreateCompatibleDC(screen);
    let mask = CreateBitmap(sz, sz, 1, 1, None);
    let mold = SelectObject(mdc, HGDIOBJ(mask.0));
    let wfill = CreateSolidBrush(COLORREF(0x00FFFFFF));
    FillRect(mdc, &full, wfill);
    let _ = DeleteObject(HGDIOBJ(wfill.0));
    let mpen = CreatePen(PS_NULL, 0, COLORREF(0));
    let mbr = CreateSolidBrush(COLORREF(0));
    let mp = SelectObject(mdc, HGDIOBJ(mpen.0));
    let mb = SelectObject(mdc, HGDIOBJ(mbr.0));
    let _ = RoundRect(mdc, 0, 0, sz, sz, r, r);
    SelectObject(mdc, mb);
    SelectObject(mdc, mp);
    let _ = DeleteObject(HGDIOBJ(mbr.0));
    let _ = DeleteObject(HGDIOBJ(mpen.0));
    SelectObject(mdc, mold);
    let _ = DeleteDC(mdc);

    ReleaseDC(None, screen);

    let ii = ICONINFO {
        fIcon: TRUE,
        xHotspot: 0,
        yHotspot: 0,
        hbmMask: mask,
        hbmColor: color,
    };
    let icon = CreateIconIndirect(&ii).unwrap_or_default();
    let _ = DeleteObject(HGDIOBJ(color.0));
    let _ = DeleteObject(HGDIOBJ(mask.0));
    icon
}

// ---- popup 绘制 ----

unsafe fn paint_popup(st: &mut UiState) {
    let hwnd = st.popup;
    let mut ps = PAINTSTRUCT::default();
    let hdc = BeginPaint(hwnd, &mut ps);

    let mut rc = RECT::default();
    let _ = GetClientRect(hwnd, &mut rc);
    let w = rc.right - rc.left;
    let h = rc.bottom - rc.top;

    let mem = CreateCompatibleDC(hdc);
    let bmp = CreateCompatibleBitmap(hdc, w, h);
    let old_bmp = SelectObject(mem, HGDIOBJ(bmp.0));

    let bg = CreateSolidBrush(COLORREF(0x00F7F7F7));
    FillRect(mem, &rc, bg);
    let _ = DeleteObject(HGDIOBJ(bg.0));
    SetBkMode(mem, TRANSPARENT);

    st.buttons.clear();
    paint_popup_body(st, mem, &rc);

    let _ = BitBlt(hdc, 0, 0, w, h, mem, 0, 0, SRCCOPY);

    SelectObject(mem, old_bmp);
    let _ = DeleteObject(HGDIOBJ(bmp.0));
    let _ = DeleteDC(mem);
    let _ = EndPaint(hwnd, &ps);
}

unsafe fn divider(hdc: HDC, x0: i32, x1: i32, y: i32) {
    let pen = CreatePen(PS_SOLID, 1, COLORREF(0x00E2E2E2));
    let old = SelectObject(hdc, HGDIOBJ(pen.0));
    let _ = MoveToEx(hdc, x0, y, None);
    let _ = LineTo(hdc, x1, y);
    SelectObject(hdc, old);
    let _ = DeleteObject(HGDIOBJ(pen.0));
}

/// 用指定图标字体绘制单个字形，居中于 rect。
unsafe fn draw_glyph(hdc: HDC, font: HFONT, glyph: char, rect: RECT, color: COLORREF) {
    let old = SelectObject(hdc, HGDIOBJ(font.0));
    SetTextColor(hdc, color);
    let mut buf = [glyph as u16];
    let mut r = rect;
    DrawTextW(hdc, &mut buf, &mut r, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOCLIP);
    SelectObject(hdc, old);
}

unsafe fn paint_popup_body(st: &mut UiState, hdc: HDC, rc: &RECT) {
    let zh = localization::is_chinese();
    let (status, connected, service_active, device, url, qr) = st.state.read(|s| {
        let status = if zh { s.status_zh.clone() } else { s.status_en.clone() };
        (
            status,
            s.connected,
            s.service_active,
            s.connected_device.clone(),
            s.advertised_url.clone(),
            s.qr.clone(),
        )
    });

    let pad = 16;
    let mut y = 16;

    // 顶部状态。
    let dot_color = if connected {
        COLORREF(0x0034C759)
    } else if service_active {
        COLORREF(0x00FF950A)
    } else {
        COLORREF(0x008E8E8E)
    };
    // 抗锯齿圆点字形，垂直居中于标题/副标题两行之间。
    let dot_rc = RECT { left: pad, top: y + 7, right: pad + 14, bottom: y + 31 };
    draw_glyph(hdc, st.font_dot, '\u{E91F}', dot_rc, dot_color);

    text_out(
        hdc,
        st.font_heading,
        COLORREF(0x00202020),
        pad + 20,
        y - 1,
        &localization::t("聊入", "Chatput"),
    );
    let line = if connected && !device.is_empty() {
        localization::t("已连接：", "Connected: ") + &device
    } else {
        status
    };
    text_out(hdc, st.font_small, COLORREF(0x00707070), pad + 20, y + 24, &line);
    y += 52;

    divider(hdc, pad, rc.right - pad, y);
    y += 12;

    // 二维码白底卡片。
    let card = 220;
    let target = 200;
    let cx = (rc.right - card) / 2;
    let card_rc = RECT { left: cx, top: y, right: cx + card, bottom: y + card };
    let white = CreateSolidBrush(COLORREF(0x00FFFFFF));
    FillRect(hdc, &card_rc, white);
    let _ = DeleteObject(HGDIOBJ(white.0));
    match qr {
        Some(qr) => {
            let qx = cx + (card - target) / 2;
            let qy = y + (card - target) / 2;
            draw_qr(hdc, &qr, qx, qy, target);
        }
        None => {
            let msg = if service_active {
                localization::t("等待二维码…", "Waiting for QR code…")
            } else {
                localization::t("服务已停止", "Service stopped")
            };
            draw_text_centered(hdc, st.font_normal, COLORREF(0x00909090), card_rc, &msg);
        }
    }
    y += card + 8;

    if !url.is_empty() {
        let r = RECT { left: rc.left, top: y, right: rc.right, bottom: y + 16 };
        draw_text_centered(hdc, st.font_small, COLORREF(0x00808080), r, &url);
        y += 18;
    }
    let hint = RECT { left: rc.left, top: y, right: rc.right, bottom: y + 16 };
    draw_text_centered(
        hdc,
        st.font_small,
        COLORREF(0x00A0A0A0),
        hint,
        &localization::t("手机扫码即可配对", "Scan with your phone to pair"),
    );

    // 底部分隔线 + 操作。
    let btn_h = 34;
    let by = rc.bottom - btn_h - 16;
    divider(hdc, pad, rc.right - pad, by - 14);

    let (toggle_btn, toggle_label, toggle_icon) = if service_active {
        (Btn::Stop, localization::t("停止", "Stop"), IconKind::Stop)
    } else {
        (Btn::Start, localization::t("启动", "Start"), IconKind::Play)
    };
    // 左：启停（强调，图标 + 文字）。
    draw_button(st, hdc, pad, by, 84, btn_h, toggle_btn, &toggle_label, Some(toggle_icon), service_active);
    // 右：设置、退出（仅图标方形按钮，对齐 macOS gearshape / power）。
    let sq = btn_h;
    let qx = rc.right - pad - sq;
    let sx = qx - 8 - sq;
    draw_button(st, hdc, sx, by, sq, btn_h, Btn::Settings, "", Some(IconKind::Gear), false);
    draw_button(st, hdc, qx, by, sq, btn_h, Btn::Quit, "", Some(IconKind::Power), false);
}

#[allow(clippy::too_many_arguments)]
unsafe fn draw_button(
    st: &mut UiState,
    hdc: HDC,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    id: Btn,
    label: &str,
    icon: Option<IconKind>,
    accent: bool,
) {
    let (fill, border, textc) = if accent {
        (COLORREF(0x00FF950A), COLORREF(0x00FF950A), COLORREF(0x00FFFFFF))
    } else {
        (COLORREF(0x00FFFFFF), COLORREF(0x00C8C8C8), COLORREF(0x00303030))
    };
    let brush = CreateSolidBrush(fill);
    let pen = CreatePen(PS_SOLID, 1, border);
    let ob = SelectObject(hdc, HGDIOBJ(brush.0));
    let op = SelectObject(hdc, HGDIOBJ(pen.0));
    let _ = RoundRect(hdc, x, y, x + w, y + h, 8, 8);
    SelectObject(hdc, ob);
    SelectObject(hdc, op);
    let _ = DeleteObject(HGDIOBJ(brush.0));
    let _ = DeleteObject(HGDIOBJ(pen.0));

    let r = RECT { left: x, top: y, right: x + w, bottom: y + h };
    if label.is_empty() {
        // 仅图标，居中。
        if let Some(k) = icon {
            draw_icon(st, hdc, k, r, textc);
        }
    } else {
        // 图标 + 文字作为整体居中。
        const ICON_W: i32 = 16;
        const GAP: i32 = 5;
        let tw = text_width(hdc, st.font_normal, label);
        let group = ICON_W + GAP + tw;
        let gx = x + (w - group) / 2;
        if let Some(k) = icon {
            let ir = RECT { left: gx, top: y, right: gx + ICON_W, bottom: y + h };
            draw_icon(st, hdc, k, ir, textc);
        }
        let tr = RECT { left: gx + ICON_W + GAP, top: y, right: gx + group, bottom: y + h };
        draw_text_left(hdc, st.font_normal, textc, tr, label);
    }
    st.buttons.push((id, r));
}

/// 用 Segoe MDL2 Assets 矢量字形绘制图标，居中于 rect。
unsafe fn draw_icon(st: &UiState, hdc: HDC, kind: IconKind, rect: RECT, color: COLORREF) {
    let glyph = match kind {
        IconKind::Play => '\u{E768}',  // Play
        IconKind::Stop => '\u{E71A}',  // Stop
        IconKind::Gear => '\u{E713}',  // Setting
        IconKind::Power => '\u{E7E8}', // PowerButton
    };
    let old = SelectObject(hdc, HGDIOBJ(st.font_icon.0));
    SetTextColor(hdc, color);
    let mut buf = [glyph as u16];
    let mut r = rect;
    DrawTextW(hdc, &mut buf, &mut r, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_NOCLIP);
    SelectObject(hdc, old);
}

// ---- 设置窗口 ----

unsafe fn open_settings(st: &mut UiState) {
    if !st.settings_win.is_invalid() {
        let _ = ShowWindow(st.settings_win, SW_SHOW);
        let _ = SetForegroundWindow(st.settings_win);
        return;
    }
    let ptr = st as *mut UiState;
    let style = WINDOW_STYLE(
        WS_OVERLAPPEDWINDOW.0 & !WS_THICKFRAME.0 & !WS_MAXIMIZEBOX.0,
    );
    let sw = GetSystemMetrics(SM_CXSCREEN);
    let sh = GetSystemMetrics(SM_CYSCREEN);
    let title = to_wide(&localization::t("聊入 · 设置", "Chatput · Settings"));
    let hwnd = CreateWindowExW(
        WINDOW_EX_STYLE::default(),
        SETTINGS_CLASS,
        PCWSTR(title.as_ptr()),
        style,
        (sw - SET_W) / 2,
        (sh - SET_H) / 2,
        SET_W,
        SET_H,
        None,
        None,
        st.hinstance,
        Some(ptr as *const c_void),
    )
    .unwrap_or_default();
    st.settings_win = hwnd;
    // 设置窗口标题栏 / 任务栏 / Alt+Tab 图标。
    if !st.app_icon.is_invalid() {
        SendMessageW(hwnd, WM_SETICON, WPARAM(ICON_BIG as usize), LPARAM(st.app_icon.0 as isize));
        SendMessageW(hwnd, WM_SETICON, WPARAM(ICON_SMALL as usize), LPARAM(st.app_icon.0 as isize));
    }
    let _ = ShowWindow(hwnd, SW_SHOW);
    let _ = SetForegroundWindow(hwnd);
}

unsafe extern "system" fn settings_wndproc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    match msg {
        WM_NCCREATE => {
            let cs = lparam.0 as *const CREATESTRUCTW;
            let ptr = (*cs).lpCreateParams as *mut UiState;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, ptr as isize);
            DefWindowProcW(hwnd, msg, wparam, lparam)
        }
        WM_CREATE => {
            if let Some(st) = state_ptr(hwnd) {
                build_settings(st, hwnd);
                SetTimer(hwnd, TIMER_LOG, 600, None);
            }
            LRESULT(0)
        }
        WM_CTLCOLOREDIT | WM_CTLCOLORSTATIC | WM_CTLCOLORBTN => {
            if msg == WM_CTLCOLOREDIT {
                let hdc = HDC(wparam.0 as *mut c_void);
                let ctl = HWND(lparam.0 as *mut c_void);
                if let Some(st) = state_ptr(hwnd) {
                    if ctl == st.ed_log {
                        SetTextColor(hdc, COLORREF(0x00000000));
                        SetBkColor(hdc, COLORREF(0x00FFFFFF));
                        let brush = GetSysColorBrush(COLOR_WINDOW);
                        return LRESULT(brush.0 as isize);
                    }
                }
            }
            // 用 Tab 页主题底色填充标签/按钮背景，使其与 Tab 页面一致（非纯白）。
            let hdc = HDC(wparam.0 as *mut c_void);
            let ctl = HWND(lparam.0 as *mut c_void);
            SetBkMode(hdc, TRANSPARENT);
            if let Some(st) = state_ptr(hwnd) {
                // 模式徽标圆点等需要自定义文字色的 STATIC。
                if msg == WM_CTLCOLORSTATIC {
                    if let Some((_, c)) = st.colored_statics.iter().find(|(h, _)| *h == ctl) {
                        SetTextColor(hdc, *c);
                    }
                }
                if !st.tab_theme.is_invalid() {
                    let mut rc = RECT::default();
                    let _ = GetClientRect(ctl, &mut rc);
                    let _ = DrawThemeBackground(st.tab_theme, hdc, TABP_BODY, 0, &rc, None);
                    return LRESULT(GetStockObject(NULL_BRUSH).0 as isize);
                }
            }
            let brush = GetSysColorBrush(COLOR_BTNFACE);
            LRESULT(brush.0 as isize)
        }
        WM_NOTIFY => {
            let nm = lparam.0 as *const NmHdr;
            if !nm.is_null() && (*nm).code == TCN_SELCHANGE {
                if let Some(st) = state_ptr(hwnd) {
                    let idx = SendMessageW(st.tab, TCM_GETCURSEL, WPARAM(0), LPARAM(0)).0 as i32;
                    apply_tab_visibility(st, idx);
                }
            }
            LRESULT(0)
        }
        WM_COMMAND => {
            if let Some(st) = state_ptr(hwnd) {
                let id = wparam.0 & 0xffff;
                let code = ((wparam.0 >> 16) & 0xffff) as u16;
                handle_settings_command(st, id, code);
            }
            LRESULT(0)
        }
        WM_REBUILD_SETTINGS => {
            if let Some(st) = state_ptr(hwnd) {
                rebuild_settings(st, hwnd);
            }
            LRESULT(0)
        }
        WM_TIMER => {
            if wparam.0 == TIMER_LOG {
                if let Some(st) = state_ptr(hwnd) {
                    if st.cur_tab == 3 {
                        refresh_log(st);
                    }
                }
            }
            LRESULT(0)
        }
        WM_CLOSE => {
            let _ = DestroyWindow(hwnd);
            LRESULT(0)
        }
        WM_DESTROY => {
            let _ = KillTimer(hwnd, TIMER_LOG);
            if let Some(st) = state_ptr(hwnd) {
                st.settings_win = HWND(null_mut());
                st.tab_ctrls.clear();
                st.colored_statics.clear();
                if !st.tab_theme.is_invalid() {
                    let _ = CloseThemeData(st.tab_theme);
                    st.tab_theme = HTHEME::default();
                }
                st.tab = HWND(null_mut());
            }
            LRESULT(0)
        }
        _ => DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

unsafe fn rebuild_settings(st: &mut UiState, hwnd: HWND) {
    if !st.tab.is_invalid() {
        let _ = DestroyWindow(st.tab);
    }
    for (_, h) in st.tab_ctrls.drain(..) {
        let _ = DestroyWindow(h);
    }
    st.colored_statics.clear();
    if !st.tab_theme.is_invalid() {
        let _ = CloseThemeData(st.tab_theme);
        st.tab_theme = HTHEME::default();
    }
    build_settings(st, hwnd);
    let _ = SetWindowTextW(
        hwnd,
        PCWSTR(to_wide(&localization::t("聊入 · 设置", "Chatput · Settings")).as_ptr()),
    );
}

unsafe fn build_settings(st: &mut UiState, hwnd: HWND) {
    let font = st.font_normal;
    // Tab 控件占据上方；表单控件是设置窗口的子窗口，背景在 WM_CTLCOLOR 中用 Tab 主题填充以保持一致。
    let tab = child(
        hwnd,
        w!("SysTabControl32"),
        "",
        WS_CLIPSIBLINGS.0,
        8,
        8,
        SET_W - 32,
        SET_H - 56,
        ID_TAB,
        font,
    );
    st.tab = tab;
    // 为设置窗口打开 Tab 主题，供 WM_CTLCOLOR 填充控件背景。
    st.tab_theme = OpenThemeData(hwnd, w!("TAB"));
    let host = hwnd; // 表单控件的父窗口（设置窗口）。
    tab_insert(tab, 0, &localization::t("通用", "General"));
    tab_insert(tab, 1, &localization::t("内置服务", "Built-in"));
    tab_insert(tab, 2, &localization::t("外部服务", "External"));
    tab_insert(tab, 3, &localization::t("日志", "Logs"));

    // 内容区原点（Tab 页内）。
    let ox = 28;
    let lw = 88; // 标签宽。
    let cx = ox + lw + 8;
    let cw = 320;
    let lf = st.font_label; // 字段标签（小）。
    let sf = st.font_small; // 描述/说明（更小）。

    // —— 通用 ——
    st.chk_launch = add_ctrl(
        st, 0, host, w!("BUTTON"),
        &localization::t("开机自动运行", "Launch at login"),
        WS_TABSTOP.0 | BS_AUTOCHECKBOX, ox, 62, 240, 22, ID_CHK_LAUNCH, font,
    );
    if st.settings.launch_at_login {
        SendMessageW(st.chk_launch, BM_SETCHECK, WPARAM(1), LPARAM(0));
    }
    add_label(st, 0, host, ox, 104, lw, &localization::t("传输模式", "Transport"), lf);
    st.cb_transport = add_combo(st, 0, host, cx, 100, cw, ID_CB_TRANSPORT, font);
    combo_add(st.cb_transport, &TransportMode::Webrtc.label());
    combo_add(st.cb_transport, &TransportMode::Websocket.label());
    combo_set(st.cb_transport, if st.settings.transport == TransportMode::Websocket { 1 } else { 0 });
    add_label_h(st, 0, host, cx, 132, cw, 34, &st.settings.transport.note(), sf);

    add_label(st, 0, host, ox, 186, lw, &localization::t("语言", "Language"), lf);
    st.cb_language = add_combo(st, 0, host, cx, 182, cw, ID_CB_LANGUAGE, font);
    combo_add(st.cb_language, &AppLanguage::System.label());
    combo_add(st.cb_language, &AppLanguage::Zh.label());
    combo_add(st.cb_language, &AppLanguage::En.label());
    combo_set(st.cb_language, match st.settings.language {
        AppLanguage::System => 0,
        AppLanguage::Zh => 1,
        AppLanguage::En => 2,
    });

    // —— 内置服务 ——
    section_header(
        st, 1, host, ox, cw + 40,
        &localization::t("内置服务（局域网）", "Built-in (LAN)"),
        &localization::t(
            "在本机运行信令服务器，手机与电脑处于同一局域网时使用。",
            "Run the signaling server locally; use it when phone and PC are on the same LAN.",
        ),
    );
    add_mode_badge(st, 1, host, ox, 122, st.settings.mode == SignalingMode::BuiltIn);
    add_label(st, 1, host, ox, 158, lw, &localization::t("监听端口", "Port"), lf);
    st.ed_port = add_edit(st, 1, host, cx, 156, 120, ID_ED_PORT, font);
    set_text(st.ed_port, &st.settings.listen_port.to_string());
    add_label(st, 1, host, ox, 192, lw, &localization::t("对外 IP", "Host IP"), lf);
    st.ed_ip = add_edit(st, 1, host, cx, 190, cw, ID_ED_IP, font);
    set_cue(st.ed_ip, &localization::t("留空自动探测", "Auto-detect if empty"));
    set_text(st.ed_ip, &st.settings.ip_override);
    let detected = network_info::primary_lan_ipv4()
        .unwrap_or_else(|| localization::t("未找到局域网地址", "no LAN address"));
    add_label(st, 1, host, cx, 220, cw, &(localization::t("自动探测：", "Detected: ") + &detected), sf);
    add_ctrl(
        st, 1, host, w!("BUTTON"),
        &localization::t("保存并应用", "Save & Apply"),
        WS_TABSTOP.0, SET_W - 60 - 150, SET_H - 96, 150, 30, ID_BTN_SAVE_BUILTIN, font,
    );

    // —— 外部服务 ——
    section_header(
        st, 2, host, ox, cw + 40,
        &localization::t("外部服务（公网远程）", "External (remote)"),
        &localization::t(
            "连接已部署在公网的信令服务器，跨网络远程使用。",
            "Connect to a signaling server on the public internet for remote use.",
        ),
    );
    add_mode_badge(st, 2, host, ox, 122, st.settings.mode == SignalingMode::External);
    add_label(st, 2, host, ox, 158, lw, &localization::t("信令地址", "Address"), lf);
    st.ed_url = add_edit(st, 2, host, cx, 156, cw, ID_ED_URL, font);
    set_cue(st.ed_url, "ws://example.com:8080");
    set_text(st.ed_url, &st.settings.external_url);
    add_label(
        st, 2, host, cx, 186, cw,
        &localization::t("二维码将广播此地址，供手机连接。", "The QR code broadcasts this address for the phone."),
        sf,
    );
    // 地址为空时仅「保存」（回退内置，不应用外部）；非空时「保存并应用」。
    st.btn_save_external = add_ctrl(
        st, 2, host, w!("BUTTON"),
        &external_save_label(&st.settings.external_url),
        WS_TABSTOP.0, SET_W - 60 - 150, SET_H - 96, 150, 30, ID_BTN_SAVE_EXTERNAL, font,
    );

    // —— 日志 ——
    st.ed_log = add_ctrl(
        st, 3, host, w!("EDIT"), "",
        WS_TABSTOP.0 | WS_BORDER.0 | WS_VSCROLL.0 | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
        ox, 56, SET_W - 32 - ox - 8, 250, ID_ED_LOG, st.font_small,
    );
    add_ctrl(
        st, 3, host, w!("BUTTON"),
        &localization::t("清空", "Clear"),
        WS_TABSTOP.0, SET_W - 60 - 100, SET_H - 96, 100, 30, ID_BTN_CLEAR, font,
    );
    refresh_log(st);

    apply_tab_visibility(st, 0);
}

unsafe fn add_mode_badge(st: &mut UiState, tab: i32, parent: HWND, x: i32, y: i32, active: bool) {
    // 圆点：生效=绿色，未启用=灰色（对齐 macOS modeBadge）。
    let dot_color = if active { COLORREF(0x0034C759) } else { COLORREF(0x00B0B0B0) };
    let dot = add_ctrl(st, tab, parent, w!("STATIC"), "\u{E91F}", SS_LEFT, x, y + 2, 14, 14, 0, st.font_dot);
    st.colored_statics.push((dot, dot_color));
    let text = if active {
        localization::t("当前生效模式", "Active mode")
    } else {
        localization::t("未启用（保存后切换到此模式）", "Inactive (save to switch here)")
    };
    add_label(st, tab, parent, x + 18, y, 360, &text, st.font_small);
}

unsafe fn apply_tab_visibility(st: &mut UiState, idx: i32) {
    st.cur_tab = idx;
    for (t, h) in &st.tab_ctrls {
        let _ = ShowWindow(*h, if *t == idx { SW_SHOW } else { SW_HIDE });
    }
    if idx == 3 {
        refresh_log(st);
    }
}

unsafe fn refresh_log(st: &UiState) {
    if st.ed_log.is_invalid() {
        return;
    }
    let text = st.state.read(|s| {
        if s.log_lines.is_empty() {
            localization::t("暂无日志", "No logs yet")
        } else {
            s.log_lines.iter().cloned().collect::<Vec<_>>().join("\r\n")
        }
    });
    set_text(st.ed_log, &text);
    // 滚动到末尾。
    let n = text.encode_utf16().count() as i32;
    SendMessageW(st.ed_log, EM_SETSEL, WPARAM(n as usize), LPARAM(n as isize));
    SendMessageW(st.ed_log, EM_SCROLLCARET, WPARAM(0), LPARAM(0));
}

unsafe fn handle_settings_command(st: &mut UiState, id: usize, code: u16) {
    match id {
        ID_CHK_LAUNCH if code == BN_CLICKED => {
            let on = SendMessageW(st.chk_launch, BM_GETCHECK, WPARAM(0), LPARAM(0)).0 == 1;
            st.settings.launch_at_login = on;
            login_item::set_enabled(on);
            st.settings.save();
        }
        ID_CB_TRANSPORT if code == CBN_SELCHANGE => {
            st.settings.transport = if combo_get(st.cb_transport) == 1 {
                TransportMode::Websocket
            } else {
                TransportMode::Webrtc
            };
            commit(st);
        }
        ID_CB_LANGUAGE if code == CBN_SELCHANGE => {
            st.settings.language = match combo_get(st.cb_language) {
                1 => AppLanguage::Zh,
                2 => AppLanguage::En,
                _ => AppLanguage::System,
            };
            st.settings.save();
            refresh_tray(st);
            let _ = InvalidateRect(st.popup, None, TRUE);
            let win = st.settings_win;
            let _ = PostMessageW(win, WM_REBUILD_SETTINGS, WPARAM(0), LPARAM(0));
        }
        ID_BTN_SAVE_BUILTIN if code == BN_CLICKED => save_with_mode(st, SignalingMode::BuiltIn),
        ID_BTN_SAVE_EXTERNAL if code == BN_CLICKED => save_with_mode(st, SignalingMode::External),
        ID_ED_URL if code == EN_CHANGE => {
            // 实时根据地址是否为空切换外部保存按钮文案。
            let url = AppSettings::normalize_external_url(read_text(st.ed_url).trim());
            set_text(st.btn_save_external, &external_save_label(&url));
        }
        ID_BTN_CLEAR if code == BN_CLICKED => {
            st.state.clear_log();
            refresh_log(st);
        }
        _ => {}
    }
}

/// 外部保存按钮文案：地址为空时仅「保存」（回退内置服务），非空时「保存并应用」。
fn external_save_label(url: &str) -> String {
    if url.trim().is_empty() {
        localization::t("保存", "Save")
    } else {
        localization::t("保存并应用", "Save & Apply")
    }
}

unsafe fn save_with_mode(st: &mut UiState, mode: SignalingMode) {
    if let Ok(port) = read_text(st.ed_port)
        .chars()
        .filter(|c| c.is_ascii_digit())
        .collect::<String>()
        .parse::<u16>()
    {
        if port > 0 {
            st.settings.listen_port = port;
        }
    }
    st.settings.ip_override = read_text(st.ed_ip).trim().to_string();
    st.settings.external_url = AppSettings::normalize_external_url(read_text(st.ed_url).trim());
    st.settings.mode = if mode == SignalingMode::External && st.settings.external_url.is_empty() {
        SignalingMode::BuiltIn
    } else {
        mode
    };
    commit(st);
    // 刷新模式徽标。
    let win = st.settings_win;
    let _ = PostMessageW(win, WM_REBUILD_SETTINGS, WPARAM(0), LPARAM(0));
}

/// 保存设置并通知协调器应用，刷新托盘与 popup。
unsafe fn commit(st: &mut UiState) {
    st.settings.save();
    let _ = st.ui_tx.send(UiCommand::ApplyConfig(Box::new(st.settings.clone())));
    refresh_tray(st);
    let _ = InvalidateRect(st.popup, None, FALSE);
}

// ---- 子控件辅助 ----

#[allow(clippy::too_many_arguments)]
unsafe fn child(
    parent: HWND,
    class: PCWSTR,
    text: &str,
    style_extra: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    id: usize,
    font: HFONT,
) -> HWND {
    let hmod = GetModuleHandleW(None).unwrap();
    let hinst = HINSTANCE(hmod.0);
    let t = to_wide(text);
    let style = WINDOW_STYLE(WS_CHILD.0 | WS_VISIBLE.0 | style_extra);
    let hwnd = CreateWindowExW(
        WINDOW_EX_STYLE::default(),
        class,
        PCWSTR(t.as_ptr()),
        style,
        x,
        y,
        w,
        h,
        parent,
        HMENU(id as *mut c_void),
        hinst,
        None,
    )
    .unwrap_or_default();
    SendMessageW(hwnd, WM_SETFONT, WPARAM(font.0 as usize), LPARAM(1));
    hwnd
}

#[allow(clippy::too_many_arguments)]
unsafe fn add_ctrl(
    st: &mut UiState,
    tab: i32,
    parent: HWND,
    class: PCWSTR,
    text: &str,
    style_extra: u32,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    id: usize,
    font: HFONT,
) -> HWND {
    let h = child(parent, class, text, style_extra, x, y, w, h, id, font);
    st.tab_ctrls.push((tab, h));
    h
}

#[allow(clippy::too_many_arguments)]
unsafe fn add_label(
    st: &mut UiState,
    tab: i32,
    parent: HWND,
    x: i32,
    y: i32,
    w: i32,
    text: &str,
    font: HFONT,
) -> HWND {
    add_ctrl(st, tab, parent, w!("STATIC"), text, SS_LEFT, x, y, w, 20, 0, font)
}

#[allow(clippy::too_many_arguments)]
unsafe fn add_label_h(
    st: &mut UiState,
    tab: i32,
    parent: HWND,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    text: &str,
    font: HFONT,
) -> HWND {
    add_ctrl(st, tab, parent, w!("STATIC"), text, SS_LEFT, x, y, w, h, 0, font)
}

/// Tab 页首：标题（大字体粗体）+ 描述（小字体），对齐 macOS sectionHeader。
unsafe fn section_header(st: &mut UiState, tab: i32, parent: HWND, x: i32, w: i32, title: &str, subtitle: &str) {
    add_label_h(st, tab, parent, x, 52, w, 24, title, st.font_heading);
    add_label_h(st, tab, parent, x, 78, w, 36, subtitle, st.font_small);
}

#[allow(clippy::too_many_arguments)]
unsafe fn add_combo(st: &mut UiState, tab: i32, parent: HWND, x: i32, y: i32, w: i32, id: usize, font: HFONT) -> HWND {
    add_ctrl(
        st, tab, parent, w!("COMBOBOX"), "",
        WS_TABSTOP.0 | WS_VSCROLL.0 | CBS_DROPDOWNLIST | CBS_HASSTRINGS,
        x, y, w, 220, id, font,
    )
}

#[allow(clippy::too_many_arguments)]
unsafe fn add_edit(st: &mut UiState, tab: i32, parent: HWND, x: i32, y: i32, w: i32, id: usize, font: HFONT) -> HWND {
    add_ctrl(
        st, tab, parent, w!("EDIT"), "",
        WS_TABSTOP.0 | WS_BORDER.0 | ES_AUTOHSCROLL,
        x, y, w, 24, id, font,
    )
}

/// 设置编辑框的占位提示（留空时灰字显示）。
unsafe fn set_cue(edit: HWND, text: &str) {
    let wide = to_wide(text);
    SendMessageW(edit, EM_SETCUEBANNER, WPARAM(1), LPARAM(wide.as_ptr() as isize));
}

unsafe fn tab_insert(tab: HWND, idx: usize, text: &str) {
    let mut wide = to_wide(text);
    let mut item = TcItemW {
        mask: TCIF_TEXT,
        dw_state: 0,
        dw_state_mask: 0,
        psz_text: wide.as_mut_ptr(),
        cch_text_max: 0,
        i_image: -1,
        l_param: 0,
    };
    SendMessageW(
        tab,
        TCM_INSERTITEMW,
        WPARAM(idx),
        LPARAM(&mut item as *mut TcItemW as isize),
    );
}

unsafe fn combo_add(h: HWND, text: &str) {
    let t = to_wide(text);
    SendMessageW(h, CB_ADDSTRING, WPARAM(0), LPARAM(t.as_ptr() as isize));
}

unsafe fn combo_set(h: HWND, idx: usize) {
    SendMessageW(h, CB_SETCURSEL, WPARAM(idx), LPARAM(0));
}

unsafe fn combo_get(h: HWND) -> i32 {
    SendMessageW(h, CB_GETCURSEL, WPARAM(0), LPARAM(0)).0 as i32
}

unsafe fn set_text(h: HWND, text: &str) {
    let t = to_wide(text);
    let _ = SetWindowTextW(h, PCWSTR(t.as_ptr()));
}

unsafe fn read_text(h: HWND) -> String {
    let mut buf = [0u16; 512];
    let n = GetWindowTextW(h, &mut buf);
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

// ---- GDI 辅助 ----

unsafe fn make_font(height: i32, weight: i32) -> HFONT {
    CreateFontW(
        height, 0, 0, 0, weight, 0, 0, 0,
        DEFAULT_CHARSET.0 as u32,
        OUT_DEFAULT_PRECIS.0 as u32,
        CLIP_DEFAULT_PRECIS.0 as u32,
        CLEARTYPE_QUALITY.0 as u32,
        0,
        w!("Microsoft YaHei UI"),
    )
}

/// Segoe MDL2 Assets 图标字体（Win10+ 系统内置矢量字形）。
unsafe fn make_icon_font(height: i32) -> HFONT {
    CreateFontW(
        height, 0, 0, 0, 400, 0, 0, 0,
        DEFAULT_CHARSET.0 as u32,
        OUT_DEFAULT_PRECIS.0 as u32,
        CLIP_DEFAULT_PRECIS.0 as u32,
        CLEARTYPE_QUALITY.0 as u32,
        0,
        w!("Segoe MDL2 Assets"),
    )
}

unsafe fn text_out(hdc: HDC, font: HFONT, color: COLORREF, x: i32, y: i32, text: &str) {
    let old = SelectObject(hdc, HGDIOBJ(font.0));
    SetTextColor(hdc, color);
    let wide: Vec<u16> = text.encode_utf16().collect();
    let _ = TextOutW(hdc, x, y, &wide);
    SelectObject(hdc, old);
}

unsafe fn draw_text_centered(hdc: HDC, font: HFONT, color: COLORREF, rect: RECT, text: &str) {
    let old = SelectObject(hdc, HGDIOBJ(font.0));
    SetTextColor(hdc, color);
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    let mut r = rect;
    DrawTextW(hdc, &mut wide, &mut r, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    SelectObject(hdc, old);
}

unsafe fn draw_text_left(hdc: HDC, font: HFONT, color: COLORREF, rect: RECT, text: &str) {
    let old = SelectObject(hdc, HGDIOBJ(font.0));
    SetTextColor(hdc, color);
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    let mut r = rect;
    DrawTextW(hdc, &mut wide, &mut r, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_NOCLIP);
    SelectObject(hdc, old);
}

unsafe fn text_width(hdc: HDC, font: HFONT, text: &str) -> i32 {
    let old = SelectObject(hdc, HGDIOBJ(font.0));
    let wide: Vec<u16> = text.encode_utf16().collect();
    let mut sz = windows::Win32::Foundation::SIZE::default();
    let _ = GetTextExtentPoint32W(hdc, &wide, &mut sz);
    SelectObject(hdc, old);
    sz.cx
}

unsafe fn draw_qr(hdc: HDC, qr: &QrImage, x: i32, y: i32, target: i32) {
    let mut bmi: BITMAPINFO = std::mem::zeroed();
    bmi.bmiHeader.biSize = std::mem::size_of::<BITMAPINFOHEADER>() as u32;
    bmi.bmiHeader.biWidth = qr.size as i32;
    bmi.bmiHeader.biHeight = -(qr.size as i32);
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = 0;

    SetStretchBltMode(hdc, COLORONCOLOR);
    StretchDIBits(
        hdc, x, y, target, target, 0, 0, qr.size as i32, qr.size as i32,
        Some(qr.rgba.as_ptr() as *const c_void),
        &bmi, DIB_RGB_COLORS, SRCCOPY,
    );
}

fn to_wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}
