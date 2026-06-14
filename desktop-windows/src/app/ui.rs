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

use windows::core::{w, PCSTR, PCWSTR};
use windows::Win32::Foundation::{
    BOOL, COLORREF, ERROR_ALREADY_EXISTS, FALSE, HANDLE, HINSTANCE, HWND, LPARAM, LRESULT, POINT,
    RECT, TRUE, WPARAM,
};
use windows::Win32::Graphics::Gdi::*;
use windows::Win32::Graphics::Dwm::{
    DwmSetWindowAttribute, DWMWA_BORDER_COLOR, DWMWA_CAPTION_COLOR, DWMWA_TEXT_COLOR,
    DWMWA_USE_IMMERSIVE_DARK_MODE,
};
use windows::Win32::System::LibraryLoader::{GetModuleHandleW, GetProcAddress, LoadLibraryW};
use windows::Win32::System::Registry::{
    RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_DWORD,
};
use windows::Win32::System::Threading::CreateMutexW;
use windows::Win32::UI::Input::KeyboardAndMouse::{ReleaseCapture, SetCapture};
use windows::Win32::UI::HiDpi::{AdjustWindowRectExForDpi, GetDpiForWindow};
use windows::Win32::UI::Controls::{
    CloseThemeData, DrawThemeBackground, InitCommonControlsEx, OpenThemeData, SetWindowTheme,
    HTHEME, ICC_TAB_CLASSES, INITCOMMONCONTROLSEX,
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
/// 主题切换后延迟重建托盘图标（等任务栏 SystemUsesLightTheme 注册表项落地）。
const TIMER_TRAY_REFRESH: usize = 3;

const POPUP_W: i32 = 300;
const POPUP_H: i32 = 420;
const SET_W: i32 = 500;
const SET_H: i32 = 380;

/// 获取主显示器 DPI 缩放系数（dpi / 96），用于高 DPI（Retina）适配。
/// PerMonitorV2 DPI 感知下，程序需自行缩放窗口和字体。
unsafe fn get_dpi_scale() -> f64 {
    let hdc = GetDC(None);
    if hdc.is_invalid() {
        return 1.0;
    }
    let dpi = GetDeviceCaps(hdc, LOGPIXELSX);
    ReleaseDC(None, hdc);
    (dpi as f64 / 96.0).max(1.0)
}

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
// 画面（2.0）
const ID_CB_FPS: usize = 2011;
const ID_CB_CODEC: usize = 2012;
const ID_CB_SCALE: usize = 2013;
const ID_CB_QUALITY: usize = 2014;
const ID_CHK_BITRATE: usize = 2015;
const ID_CHK_AUTO_ROOM: usize = 2017;
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
const EM_REPLACESEL: u32 = 0x00C2;
const EM_SETCUEBANNER: u32 = 0x1501;
// Listbox 消息。
const LB_ADDSTRING: u32 = 0x0180;
const LB_RESETCONTENT: u32 = 0x0184;
const LB_GETCURSEL: u32 = 0x0188;
const LB_SETCURSEL: u32 = 0x0186;
const LB_GETCOUNT: u32 = 0x018B;
const LB_GETTOPINDEX: u32 = 0x018E;
const LB_SETTOPINDEX: u32 = 0x0197;
// Listbox 样式。
const LBS_NOINTEGRALHEIGHT: u32 = 0x0100;

// Tab 控件消息 / 通知。
const TCM_FIRST: u32 = 0x1300;
const TCM_INSERTITEMW: u32 = TCM_FIRST + 62;
const TCM_GETCURSEL: u32 = TCM_FIRST + 11;
const TCM_SETCURSEL: u32 = TCM_FIRST + 12;
const TCM_GETITEMCOUNT: u32 = TCM_FIRST + 4;
const TCM_GETITEMRECT: u32 = TCM_FIRST + 10;
const TCM_GETITEMW: u32 = TCM_FIRST + 60;
const TCM_ADJUSTRECT: u32 = TCM_FIRST + 40;

// 编辑控件消息（windows crate 未在 glob 中导出，按 Win32 文档常量手动声明）。
const EM_GETRECT: u32 = 0x00B2;
const EM_LINESCROLL: u32 = 0x00B6;
const EM_GETLINECOUNT: u32 = 0x00BA;
const EM_GETFIRSTVISIBLELINE: u32 = 0x00CE;
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

// ---- 主题（明亮 / 暗夜，随系统 AppsUseLightTheme 切换）----

/// 强调色（橙色 #0A95FF→实为 #FF950A？此处沿用既有 accent）。COLORREF 为 BGR。
const ACCENT: COLORREF = COLORREF(0x00FF950A);
const ACCENT_TEXT: COLORREF = COLORREF(0x00FFFFFF);
const STATE_CONNECTED: COLORREF = COLORREF(0x0034C759); // 绿
const STATE_ACTIVE: COLORREF = COLORREF(0x00FF950A); // 橙
const STATE_IDLE_LIGHT: COLORREF = COLORREF(0x008E8E8E);
const STATE_IDLE_DARK: COLORREF = COLORREF(0x00808080);

/// 一套界面配色。COLORREF 中性灰对称，无需关心 BGR 顺序。
#[derive(Clone, Copy)]
struct Theme {
    dark: bool,
    popup_bg: COLORREF,    // popup 背景
    surface: COLORREF,     // 卡片 / 次级按钮底
    line: COLORREF,        // 分隔线
    border: COLORREF,      // 控件描边
    text_primary: COLORREF,
    text_secondary: COLORREF,
    text_tertiary: COLORREF,
    button_text: COLORREF, // 次级按钮文字
    control_bg: COLORREF,  // 编辑框 / 日志底
    control_text: COLORREF,
    idle_dot: COLORREF,    // 空闲状态圆点
    badge_idle: COLORREF,  // 模式徽标未启用圆点
}

const LIGHT_THEME: Theme = Theme {
    dark: false,
    popup_bg: COLORREF(0x00F7F7F7),
    surface: COLORREF(0x00FFFFFF),
    line: COLORREF(0x00E2E2E2),
    border: COLORREF(0x00C8C8C8),
    text_primary: COLORREF(0x00202020),
    text_secondary: COLORREF(0x00707070),
    text_tertiary: COLORREF(0x00A0A0A0),
    button_text: COLORREF(0x00303030),
    control_bg: COLORREF(0x00FFFFFF),
    control_text: COLORREF(0x00000000),
    idle_dot: STATE_IDLE_LIGHT,
    badge_idle: COLORREF(0x00B0B0B0),
};

const DARK_THEME: Theme = Theme {
    dark: true,
    popup_bg: COLORREF(0x001E1E1E),
    surface: COLORREF(0x002B2B2B),
    line: COLORREF(0x003A3A3A),
    border: COLORREF(0x004A4A4A),
    text_primary: COLORREF(0x00F2F2F2),
    text_secondary: COLORREF(0x00B0B0B0),
    text_tertiary: COLORREF(0x00808080),
    button_text: COLORREF(0x00E6E6E6),
    control_bg: COLORREF(0x00262626),
    control_text: COLORREF(0x00F2F2F2),
    idle_dot: STATE_IDLE_DARK,
    badge_idle: COLORREF(0x00666666),
};

/// 应用是否使用浅色主题（Win10/11 个性化设置）。失败默认浅色。
unsafe fn apps_use_light_theme() -> bool {
    let mut val: u32 = 1;
    let mut sz = std::mem::size_of::<u32>() as u32;
    let r = RegGetValueW(
        HKEY_CURRENT_USER,
        w!("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        w!("AppsUseLightTheme"),
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

/// 当前应使用的配色。
unsafe fn current_theme() -> Theme {
    if apps_use_light_theme() {
        LIGHT_THEME
    } else {
        DARK_THEME
    }
}

// uxtheme 私有序号 API：让原生控件（复选框/下拉/滚动条等）跟随暗色。
type FnSetPreferredAppMode = unsafe extern "system" fn(i32) -> i32;
type FnAllowDarkModeForWindow = unsafe extern "system" fn(HWND, BOOL) -> BOOL;
type FnFlushMenuThemes = unsafe extern "system" fn();

/// 进程级偏好：0=Default 1=AllowDark 2=ForceDark 3=ForceLight。仅在 Win10 1809+ 可用。
unsafe fn set_preferred_app_mode(dark: bool) {
    let Ok(lib) = LoadLibraryW(w!("uxtheme.dll")) else {
        return;
    };
    if let Some(p) = GetProcAddress(lib, PCSTR(135usize as *const u8)) {
        let f: FnSetPreferredAppMode = std::mem::transmute(p);
        f(if dark { 1 } else { 0 });
    }
    if let Some(p) = GetProcAddress(lib, PCSTR(136usize as *const u8)) {
        let flush: FnFlushMenuThemes = std::mem::transmute(p);
        flush();
    }
}

/// 允许某窗口启用暗色（私有序号 133）。
unsafe fn allow_dark_for_window(hwnd: HWND, allow: bool) {
    let Ok(lib) = LoadLibraryW(w!("uxtheme.dll")) else {
        return;
    };
    if let Some(p) = GetProcAddress(lib, PCSTR(133usize as *const u8)) {
        let f: FnAllowDarkModeForWindow = std::mem::transmute(p);
        let _ = f(hwnd, BOOL(allow as i32));
    }
}

/// 标题栏暗色（DWM 官方属性，Win10 2004+）。
/// 暗色下进一步用 DWMWA_CAPTION_COLOR/BORDER_COLOR 把标题栏染成与窗体一致的颜色，
/// 消除系统默认深色标题栏与自绘窗体之间的割裂（Win11 22000+ 生效）。
unsafe fn set_titlebar_dark(hwnd: HWND, dark: bool) {
    let v = BOOL(dark as i32);
    let _ = DwmSetWindowAttribute(
        hwnd,
        DWMWA_USE_IMMERSIVE_DARK_MODE,
        &v as *const _ as *const c_void,
        std::mem::size_of::<BOOL>() as u32,
    );
    let theme = if dark { DARK_THEME } else { LIGHT_THEME };
    let caption = theme.popup_bg;
    let _ = DwmSetWindowAttribute(
        hwnd,
        DWMWA_CAPTION_COLOR,
        &caption as *const _ as *const c_void,
        std::mem::size_of::<COLORREF>() as u32,
    );
    let _ = DwmSetWindowAttribute(
        hwnd,
        DWMWA_BORDER_COLOR,
        &caption as *const _ as *const c_void,
        std::mem::size_of::<COLORREF>() as u32,
    );
    let text = theme.text_primary;
    let _ = DwmSetWindowAttribute(
        hwnd,
        DWMWA_TEXT_COLOR,
        &text as *const _ as *const c_void,
        std::mem::size_of::<COLORREF>() as u32,
    );
}

/// 给原生子控件套暗色主题（滚动条/复选框/下拉箭头）。
unsafe fn apply_control_theme(hwnd: HWND, dark: bool) {
    allow_dark_for_window(hwnd, dark);
    let theme = if dark { w!("DarkMode_Explorer") } else { w!("Explorer") };
    let _ = SetWindowTheme(hwnd, theme, None);
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
    /// 当前配色（随系统明暗切换）。
    theme: Theme,
    /// 设置窗口背景刷（暗色时用于填充客户区与控件背景）。
    bg_brush: HBRUSH,
    /// 设置窗口编辑框 / 日志背景刷。
    ctrl_brush: HBRUSH,
    /// 主显示器 DPI 缩放系数（dpi / 96），用于高 DPI（Retina）适配。
    dpi_scale: f64,
    /// 设置窗口专属 DPI 缩放（随窗口所在显示器变化，独立于 popup）。
    set_scale: f64,
    /// 设置窗口专属字体（按 set_scale 重建，避免影响 popup 字体）。
    sf_heading: HFONT,
    sf_normal: HFONT,
    sf_label: HFONT,
    sf_small: HFONT,
    sf_dot: HFONT,
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
    /// 日志框的自绘暗色滚动条（替代原生黑色滚动条）。
    log_sb: HWND,
    /// 滚动条拖动中标记与拖动起点相对滑块顶部的偏移。
    sb_drag: bool,
    sb_drag_off: i32,
    btn_save_external: HWND,
    // 画面 Tab（2.0）
    cb_fps: HWND,
    cb_codec: HWND,
    cb_scale: HWND,
    cb_quality: HWND,
    chk_bitrate: HWND,
    // 通用 Tab 扩展（2.0）
    chk_auto_room: HWND,
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
            if !self.bg_brush.is_invalid() {
                let _ = DeleteObject(HGDIOBJ(self.bg_brush.0));
            }
            if !self.ctrl_brush.is_invalid() {
                let _ = DeleteObject(HGDIOBJ(self.ctrl_brush.0));
            }
            destroy_set_fonts(self);
        }
    }
}

const POPUP_CLASS: PCWSTR = w!("ChatputPopup");
const SETTINGS_CLASS: PCWSTR = w!("ChatputSettings");
const LOG_SB_CLASS: PCWSTR = w!("ChatputLogScrollbar");

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
        // 不设 CS_HREDRAW | CS_VREDRAW：该窗口禁止 resize，不需要这些 style。
        let set_wc = WNDCLASSW {
            style: WNDCLASS_STYLES::default(),
            lpfnWndProc: Some(settings_wndproc),
            hInstance: hinstance,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            hbrBackground: HBRUSH((COLOR_WINDOW.0 + 1) as isize as *mut c_void),
            lpszClassName: SETTINGS_CLASS,
            ..Default::default()
        };
        RegisterClassW(&set_wc);

        // 日志自绘滚动条窗口类（暗色下替换原生黑色滚动条）。
        let sb_wc = WNDCLASSW {
            style: CS_HREDRAW | CS_VREDRAW,
            lpfnWndProc: Some(log_scrollbar_wndproc),
            hInstance: hinstance,
            hCursor: LoadCursorW(None, IDC_ARROW).unwrap_or_default(),
            lpszClassName: LOG_SB_CLASS,
            ..Default::default()
        };
        RegisterClassW(&sb_wc);

        // 读取当前系统主题，并让原生控件可跟随暗色。
        let theme = current_theme();
        set_preferred_app_mode(theme.dark);
        let (bg_brush, ctrl_brush) = if theme.dark {
            (CreateSolidBrush(theme.popup_bg), CreateSolidBrush(theme.control_bg))
        } else {
            (HBRUSH(null_mut()), HBRUSH(null_mut()))
        };

        let dpi_scale = get_dpi_scale();

        let st = Box::new(UiState {
            state,
            settings,
            ui_tx,
            hinstance,
            popup: HWND(null_mut()),
            settings_win: HWND(null_mut()),
            last_hide: None,
            buttons: Vec::new(),
            font_heading: make_font(-(17.0 * dpi_scale) as i32, 700),
            font_normal: make_font(-(15.0 * dpi_scale) as i32, 400),
            font_label: make_font(-(13.0 * dpi_scale) as i32, 400),
            font_small: make_font(-(12.0 * dpi_scale) as i32, 400),
            font_icon: make_icon_font(-(15.0 * dpi_scale) as i32),
            font_dot: make_icon_font(-(11.0 * dpi_scale) as i32),
            tray_icon: create_tray_icon(),
            app_icon: create_app_icon(256),
            nid: NOTIFYICONDATAW::default(),
            theme,
            bg_brush,
            ctrl_brush,
            dpi_scale,
            set_scale: dpi_scale,
            sf_heading: HFONT(null_mut()),
            sf_normal: HFONT(null_mut()),
            sf_label: HFONT(null_mut()),
            sf_small: HFONT(null_mut()),
            sf_dot: HFONT(null_mut()),
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
            log_sb: HWND(null_mut()),
            sb_drag: false,
            sb_drag_off: 0,
            btn_save_external: HWND(null_mut()),
            cb_fps: HWND(null_mut()),
            cb_codec: HWND(null_mut()),
            cb_scale: HWND(null_mut()),
            cb_quality: HWND(null_mut()),
            chk_bitrate: HWND(null_mut()),
            chk_auto_room: HWND(null_mut()),
        });
        let ptr = Box::into_raw(st);

        let style = WINDOW_STYLE(WS_POPUP.0);
        let pw = (POPUP_W as f64 * dpi_scale) as i32;
        let ph = (POPUP_H as f64 * dpi_scale) as i32;
        let popup = CreateWindowExW(
            WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
            POPUP_CLASS,
            w!("ChatPUT"),
            style,
            0,
            0,
            pw,
            ph,
            None,
            None,
            hinstance,
            Some(ptr as *const c_void),
        )
        .expect("create popup");

        position_popup(popup);
        let _ = ShowWindow(popup, SW_SHOW);
        let _ = SetForegroundWindow(popup);

        // 测试辅助：CHATPUT_OPEN_SETTINGS 环境变量存在时直接打开设置窗口，便于截图核对布局。
        // 取值为 0..4 时同时切换到对应 tab。
        if let Ok(v) = std::env::var("CHATPUT_OPEN_SETTINGS") {
            if let Some(st) = state_ptr(popup) {
                open_settings(st);
                if let Ok(idx) = v.parse::<i32>() {
                    if (0..5).contains(&idx) {
                        SendMessageW(st.tab, TCM_SETCURSEL, WPARAM(idx as usize), LPARAM(0));
                        apply_tab_visibility(st, idx);
                    }
                }
            }
        }

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
            if wparam.0 == TIMER_TRAY_REFRESH {
                // 一次性：主题切换后注册表已稳定，按当前任务栏明暗重建托盘图标。
                let _ = KillTimer(hwnd, TIMER_TRAY_REFRESH);
                if let Some(st) = state_ptr(hwnd) {
                    let old_icon = st.tray_icon;
                    st.tray_icon = create_tray_icon();
                    refresh_tray(st);
                    if !old_icon.is_invalid() {
                        let _ = DestroyIcon(old_icon);
                    }
                }
                return LRESULT(0);
            }
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
        WM_SETTINGCHANGE => {
            // 系统明暗主题切换会广播此消息（lParam 指向 "ImmersiveColorSet"）。
            if let Some(st) = state_ptr(hwnd) {
                refresh_theme(st);
            }
            DefWindowProcW(hwnd, msg, wparam, lparam)
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
    let mut cr = RECT::default();
    let _ = GetWindowRect(hwnd, &mut cr);
    let w = cr.right - cr.left;
    let h = cr.bottom - cr.top;
    let x = (wa.right - w - 8).max(wa.left + 8);
    let y = (wa.bottom - h - 8).max(wa.top + 8);
    let _ = SetWindowPos(hwnd, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
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
    let tip: Vec<u16> = localization::t("ChatPUT", "ChatPUT")
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

/// 系统明暗主题切换：刷新配色、画刷、托盘图标，并重绘 popup 与设置窗口。
unsafe fn refresh_theme(st: &mut UiState) {
    let new = current_theme();
    if new.dark == st.theme.dark {
        return;
    }
    st.theme = new;
    set_preferred_app_mode(new.dark);

    // 重建暗色画刷。
    if !st.bg_brush.is_invalid() {
        let _ = DeleteObject(HGDIOBJ(st.bg_brush.0));
        st.bg_brush = HBRUSH(null_mut());
    }
    if !st.ctrl_brush.is_invalid() {
        let _ = DeleteObject(HGDIOBJ(st.ctrl_brush.0));
        st.ctrl_brush = HBRUSH(null_mut());
    }
    if new.dark {
        st.bg_brush = CreateSolidBrush(new.popup_bg);
        st.ctrl_brush = CreateSolidBrush(new.control_bg);
    }

    // 托盘图标随任务栏明暗重绘。
    let old_icon = st.tray_icon;
    st.tray_icon = create_tray_icon();
    refresh_tray(st);
    if !old_icon.is_invalid() {
        let _ = DestroyIcon(old_icon);
    }
    // 任务栏的 SystemUsesLightTheme 注册表项在广播此消息时可能尚未落地，
    // 故再安排一次延迟重建，确保托盘图标颜色最终与任务栏一致。
    SetTimer(st.popup, TIMER_TRAY_REFRESH, 600, None);

    let _ = InvalidateRect(st.popup, None, TRUE);

    // 设置窗口若已打开：更新标题栏并重建控件以套用新主题。
    if !st.settings_win.is_invalid() {
        allow_dark_for_window(st.settings_win, new.dark);
        set_titlebar_dark(st.settings_win, new.dark);
        let win = st.settings_win;
        let _ = InvalidateRect(win, None, TRUE);
        let _ = PostMessageW(win, WM_REBUILD_SETTINGS, WPARAM(0), LPARAM(0));
    }
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

    let bg = CreateSolidBrush(st.theme.popup_bg);
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

unsafe fn divider(hdc: HDC, x0: i32, x1: i32, y: i32, color: COLORREF) {
    let pen = CreatePen(PS_SOLID, 1, color);
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

    let s = st.dpi_scale;
    let pad = (16.0 * s) as i32;
    let mut y = pad;

    // 顶部状态。
    let dot_color = if connected {
        STATE_CONNECTED
    } else if service_active {
        STATE_ACTIVE
    } else {
        st.theme.idle_dot
    };
    // 抗锯齿圆点字形，垂直居中于标题/副标题两行之间。
    let dot_rc = RECT { left: pad, top: y + (7.0 * s) as i32, right: pad + (14.0 * s) as i32, bottom: y + (31.0 * s) as i32 };
    draw_glyph(hdc, st.font_dot, '\u{E91F}', dot_rc, dot_color);

    text_out(
        hdc,
        st.font_heading,
        st.theme.text_primary,
        pad + (20.0 * s) as i32,
        y - (1.0 * s) as i32,
        &localization::t("ChatPUT", "ChatPUT"),
    );
    let line = if connected && !device.is_empty() {
        localization::t("已连接：", "Connected: ") + &device
    } else {
        status
    };
    text_out(hdc, st.font_small, st.theme.text_secondary, pad + (20.0 * s) as i32, y + (24.0 * s) as i32, &line);
    y += (52.0 * s) as i32;

    divider(hdc, pad, rc.right - pad, y, st.theme.line);
    y += (12.0 * s) as i32;

    // 二维码白底卡片。
    let card = (220.0 * s) as i32;
    let target = (200.0 * s) as i32;
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
    y += card + (8.0 * s) as i32;

    if !url.is_empty() {
        let r = RECT { left: rc.left, top: y, right: rc.right, bottom: y + (16.0 * s) as i32 };
        draw_text_centered(hdc, st.font_small, st.theme.text_secondary, r, &url);
        y += (18.0 * s) as i32;
    }
    let hint = RECT { left: rc.left, top: y, right: rc.right, bottom: y + (16.0 * s) as i32 };
    draw_text_centered(
        hdc,
        st.font_small,
        st.theme.text_tertiary,
        hint,
        &localization::t("手机扫码即可配对", "Scan with your phone to pair"),
    );

    // 底部分隔线 + 操作。
    let btn_h = (34.0 * s) as i32;
    let by = rc.bottom - btn_h - pad;
    divider(hdc, pad, rc.right - pad, by - (14.0 * s) as i32, st.theme.line);

    let (toggle_btn, toggle_label, toggle_icon) = if service_active {
        (Btn::Stop, localization::t("停止", "Stop"), IconKind::Stop)
    } else {
        (Btn::Start, localization::t("启动", "Start"), IconKind::Play)
    };
    // 左：启停（强调，图标 + 文字）。
    draw_button(st, hdc, pad, by, (84.0 * s) as i32, btn_h, toggle_btn, &toggle_label, Some(toggle_icon), service_active);
    // 右：设置、退出（仅图标方形按钮，对齐 macOS gearshape / power）。
    let sq = btn_h;
    let qx = rc.right - pad - sq;
    let sx = qx - (8.0 * s) as i32 - sq;
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
        (ACCENT, ACCENT, ACCENT_TEXT)
    } else {
        (st.theme.surface, st.theme.border, st.theme.button_text)
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
        let icon_w = (16.0 * st.dpi_scale) as i32;
        let gap = (5.0 * st.dpi_scale) as i32;
        let tw = text_width(hdc, st.font_normal, label);
        let group = icon_w + gap + tw;
        let gx = x + (w - group) / 2;
        if let Some(k) = icon {
            let ir = RECT { left: gx, top: y, right: gx + icon_w, bottom: y + h };
            draw_icon(st, hdc, k, ir, textc);
        }
        let tr = RECT { left: gx + icon_w + gap, top: y, right: gx + group, bottom: y + h };
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
        let win = st.settings_win;
        // 若被最小化先还原，再强制置顶到前台（被其他窗口覆盖时也能切回）。
        if IsIconic(win).as_bool() {
            let _ = ShowWindow(win, SW_RESTORE);
        } else {
            let _ = ShowWindow(win, SW_SHOW);
        }
        let _ = BringWindowToTop(win);
        let _ = SetForegroundWindow(win);
        return;
    }
    let ptr = st as *mut UiState;
    let style = WINDOW_STYLE(
        (WS_OVERLAPPEDWINDOW.0 & !WS_THICKFRAME.0 & !WS_MAXIMIZEBOX.0) | WS_CLIPCHILDREN.0,
    );
    let screen_w = GetSystemMetrics(SM_CXSCREEN);
    let screen_h = GetSystemMetrics(SM_CYSCREEN);
    let set_w = (SET_W as f64 * st.dpi_scale) as i32;
    let set_h = (SET_H as f64 * st.dpi_scale) as i32;
    let title = to_wide(&localization::t("ChatPUT · 设置", "ChatPUT · Settings"));
    let hwnd = CreateWindowExW(
        WINDOW_EX_STYLE::default(),
        SETTINGS_CLASS,
        PCWSTR(title.as_ptr()),
        style,
        (screen_w - set_w) / 2,
        (screen_h - set_h) / 2,
        set_w,
        set_h,
        None,
        None,
        st.hinstance,
        Some(ptr as *const c_void),
    )
    .unwrap_or_default();
    st.settings_win = hwnd;
    // 暗色：标题栏 + 窗口暗色，原生控件随之变深。
    if st.theme.dark {
        allow_dark_for_window(hwnd, true);
        set_titlebar_dark(hwnd, true);
    }
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
                SetTimer(hwnd, TIMER_LOG, 2000, None);
            }
            LRESULT(0)
        }
        WM_CTLCOLOREDIT | WM_CTLCOLORSTATIC | WM_CTLCOLORBTN | WM_CTLCOLORLISTBOX => {
            let hdc = HDC(wparam.0 as *mut c_void);
            let ctl = HWND(lparam.0 as *mut c_void);
            // 日志编辑框为 ES_READONLY，系统发的是 WM_CTLCOLORSTATIC 而非 EDIT。
            // 必须最先单独处理：用 OPAQUE 背景 + 实心画刷，避免被通用 STATIC 分支
            // 设成 TRANSPARENT + DrawThemeBackground + NULL_BRUSH——那会导致选中文本时
            // 仅选中行重绘、其余行因透明/空刷而看不见。
            if let Some(st) = state_ptr(hwnd) {
                if ctl == st.ed_log && !st.ed_log.is_invalid() {
                    SetBkMode(hdc, OPAQUE);
                    if st.theme.dark {
                        SetTextColor(hdc, st.theme.control_text);
                        SetBkColor(hdc, st.theme.control_bg);
                        return LRESULT(st.ctrl_brush.0 as isize);
                    } else {
                        SetTextColor(hdc, COLORREF(0x00000000));
                        SetBkColor(hdc, COLORREF(0x00FFFFFF));
                        let brush = GetSysColorBrush(COLOR_WINDOW);
                        return LRESULT(brush.0 as isize);
                    }
                }
            }
            // 暗色：编辑框走深底深字，标签/按钮透明文字置于暗背景上。
            if let Some(st) = state_ptr(hwnd) {
                if st.theme.dark {
                    if msg == WM_CTLCOLORLISTBOX {
                        // 下拉框展开后的列表：深底深字。
                        SetTextColor(hdc, st.theme.control_text);
                        SetBkColor(hdc, st.theme.control_bg);
                        return LRESULT(st.ctrl_brush.0 as isize);
                    }
                    if msg == WM_CTLCOLOREDIT {
                        SetBkMode(hdc, OPAQUE);
                        SetTextColor(hdc, st.theme.control_text);
                        SetBkColor(hdc, st.theme.control_bg);
                        return LRESULT(st.ctrl_brush.0 as isize);
                    }
                    SetBkMode(hdc, TRANSPARENT);
                    let text = st
                        .colored_statics
                        .iter()
                        .find(|(h, _)| *h == ctl)
                        .map(|(_, c)| *c)
                        .unwrap_or(st.theme.text_primary);
                    SetTextColor(hdc, text);
                    SetBkColor(hdc, st.theme.popup_bg);
                    return LRESULT(st.bg_brush.0 as isize);
                }
            }
            // 浅色下拉列表：交给系统默认绘制，避免误用 Tab 页底色导致悬停文字异常。
            if msg == WM_CTLCOLORLISTBOX {
                return DefWindowProcW(hwnd, msg, wparam, lparam);
            }
            // CBS_DROPDOWNLIST 下拉框的面会发 WM_CTLCOLORSTATIC；若按普通标签用 Tab 底色
            // 覆盖其客户区，会把边框与下拉箭头一起涂掉。故交给系统默认绘制。
            if let Some(st) = state_ptr(hwnd) {
                if ctl == st.cb_transport
                    || ctl == st.cb_language
                    || ctl == st.cb_codec
                    || ctl == st.cb_fps
                    || ctl == st.cb_scale
                    || ctl == st.cb_quality
                {
                    return DefWindowProcW(hwnd, msg, wparam, lparam);
                }
            }
            // 用 Tab 页主题底色填充标签/按钮背景，使其与 Tab 页面一致（非纯白）。
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
        WM_ERASEBKGND => {
            if let Some(st) = state_ptr(hwnd) {
                if st.theme.dark && !st.bg_brush.is_invalid() {
                    let hdc = HDC(wparam.0 as *mut c_void);
                    let mut rc = RECT::default();
                    let _ = GetClientRect(hwnd, &mut rc);
                    FillRect(hdc, &rc, st.bg_brush);
                    return LRESULT(1);
                }
            }
            DefWindowProcW(hwnd, msg, wparam, lparam)
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
        WM_DPICHANGED => {
            // 系统建议的新窗口矩形（位置+尺寸）随新 DPI 给出；先应用再按新缩放重排控件。
            let rc = &*(lparam.0 as *const RECT);
            let _ = SetWindowPos(
                hwnd,
                None,
                rc.left,
                rc.top,
                rc.right - rc.left,
                rc.bottom - rc.top,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
            if let Some(st) = state_ptr(hwnd) {
                rebuild_settings(st, hwnd);
            }
            LRESULT(0)
        }
        WM_TIMER => {
            if wparam.0 == TIMER_LOG {
                if let Some(st) = state_ptr(hwnd) {
                    if st.cur_tab == 4 {
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

/// Tab 控件子类过程：暗色主题下完全自绘标签与页面背景。
/// 原生 SysTabControl32 在暗色下仍画浅色标签/边框，故拦截 WM_PAINT 自绘：
/// 客户区填暗背景（表单控件为兄弟窗口，受 WS_CLIPSIBLINGS 裁剪不会被覆盖），
/// 再逐个标签绘制文字与选中高亮。
unsafe extern "system" fn tab_dark_wndproc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let prev = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    let call_prev = |m: u32, w: WPARAM, l: LPARAM| -> LRESULT {
        if prev != 0 {
            let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT =
                std::mem::transmute(prev as usize);
            f(hwnd, m, w, l)
        } else {
            DefWindowProcW(hwnd, m, w, l)
        }
    };
    let st_ptr = GetPropW(hwnd, w!("ChatputState")).0 as *const UiState;
    let dark = !st_ptr.is_null() && (*st_ptr).theme.dark;
    if !dark {
        return call_prev(msg, wparam, lparam);
    }
    let st = &*st_ptr;
    match msg {
        WM_ERASEBKGND => {
            let hdc = HDC(wparam.0 as *mut c_void);
            let mut rc = RECT::default();
            let _ = GetClientRect(hwnd, &mut rc);
            FillRect(hdc, &rc, st.bg_brush);
            LRESULT(1)
        }
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let hdc = BeginPaint(hwnd, &mut ps);
            let mut client = RECT::default();
            let _ = GetClientRect(hwnd, &mut client);
            FillRect(hdc, &client, st.bg_brush);

            let font = HFONT(SendMessageW(hwnd, WM_GETFONT, WPARAM(0), LPARAM(0)).0 as *mut c_void);
            let old_font = SelectObject(hdc, HGDIOBJ(font.0));
            SetBkMode(hdc, TRANSPARENT);

            let count = SendMessageW(hwnd, TCM_GETITEMCOUNT, WPARAM(0), LPARAM(0)).0 as i32;
            let sel = SendMessageW(hwnd, TCM_GETCURSEL, WPARAM(0), LPARAM(0)).0 as i32;
            for i in 0..count {
                let mut rc = RECT::default();
                SendMessageW(
                    hwnd,
                    TCM_GETITEMRECT,
                    WPARAM(i as usize),
                    LPARAM(&mut rc as *mut RECT as isize),
                );
                let mut buf = [0u16; 64];
                let mut item = TcItemW {
                    mask: TCIF_TEXT,
                    dw_state: 0,
                    dw_state_mask: 0,
                    psz_text: buf.as_mut_ptr(),
                    cch_text_max: buf.len() as i32,
                    i_image: 0,
                    l_param: 0,
                };
                SendMessageW(
                    hwnd,
                    TCM_GETITEMW,
                    WPARAM(i as usize),
                    LPARAM(&mut item as *mut TcItemW as isize),
                );
                if i == sel {
                    FillRect(hdc, &rc, st.ctrl_brush);
                    SetTextColor(hdc, st.theme.text_primary);
                } else {
                    SetTextColor(hdc, st.theme.text_secondary);
                }
                let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
                let mut tr = rc;
                DrawTextW(hdc, &mut buf[..len], &mut tr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            }
            SelectObject(hdc, old_font);
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        WM_NCDESTROY => {
            let _ = RemovePropW(hwnd, w!("ChatputState"));
            call_prev(msg, wparam, lparam)
        }
        _ => call_prev(msg, wparam, lparam),
    }
}

/// 日志框可见区域行高（含行间距）。
unsafe fn log_line_height(edit: HWND) -> i32 {
    let hdc = GetDC(edit);
    let font = HFONT(SendMessageW(edit, WM_GETFONT, WPARAM(0), LPARAM(0)).0 as *mut c_void);
    let old = SelectObject(hdc, HGDIOBJ(font.0));
    let mut tm = TEXTMETRICW::default();
    let _ = GetTextMetricsW(hdc, &mut tm);
    SelectObject(hdc, old);
    ReleaseDC(edit, hdc);
    (tm.tmHeight + tm.tmExternalLeading).max(1)
}

/// 返回日志框 (首个可见行, 总行数, 可见行数)。
unsafe fn log_scroll_metrics(edit: HWND) -> (i32, i32, i32) {
    let total = (SendMessageW(edit, EM_GETLINECOUNT, WPARAM(0), LPARAM(0)).0 as i32).max(1);
    let first = SendMessageW(edit, EM_GETFIRSTVISIBLELINE, WPARAM(0), LPARAM(0)).0 as i32;
    let mut rc = RECT::default();
    SendMessageW(edit, EM_GETRECT, WPARAM(0), LPARAM(&mut rc as *mut RECT as isize));
    let visible = ((rc.bottom - rc.top) / log_line_height(edit)).max(1);
    (first, total, visible)
}

/// 子类化日志框：滚轮滚动并刷新自绘滚动条。
unsafe extern "system" fn log_edit_wndproc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let prev = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    let call_prev = |m: u32, w: WPARAM, l: LPARAM| -> LRESULT {
        if prev != 0 {
            let f: unsafe extern "system" fn(HWND, u32, WPARAM, LPARAM) -> LRESULT =
                std::mem::transmute(prev as usize);
            f(hwnd, m, w, l)
        } else {
            DefWindowProcW(hwnd, m, w, l)
        }
    };
    match msg {
        WM_MOUSEWHEEL => {
            let delta = ((wparam.0 >> 16) & 0xFFFF) as i16 as i32;
            let lines = -(delta / 120) * 3;
            SendMessageW(hwnd, EM_LINESCROLL, WPARAM(0), LPARAM(lines as isize));
            let sb = GetPropW(hwnd, w!("ChatputLogSb"));
            if !sb.0.is_null() {
                let _ = InvalidateRect(HWND(sb.0), None, FALSE);
            }
            LRESULT(0)
        }
        WM_KEYDOWN | WM_KEYUP | WM_LBUTTONUP => {
            let r = call_prev(msg, wparam, lparam);
            let sb = GetPropW(hwnd, w!("ChatputLogSb"));
            if !sb.0.is_null() {
                let _ = InvalidateRect(HWND(sb.0), None, FALSE);
            }
            r
        }
        WM_NCDESTROY => {
            let _ = RemovePropW(hwnd, w!("ChatputState"));
            let _ = RemovePropW(hwnd, w!("ChatputLogSb"));
            call_prev(msg, wparam, lparam)
        }
        _ => call_prev(msg, wparam, lparam),
    }
}

/// 日志自绘暗色滚动条窗口过程。
unsafe extern "system" fn log_scrollbar_wndproc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> LRESULT {
    let st_ptr = GetPropW(hwnd, w!("ChatputState")).0 as *mut UiState;
    if st_ptr.is_null() {
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    let st = &mut *st_ptr;
    let edit = st.ed_log;
    let track_h = {
        let mut rc = RECT::default();
        let _ = GetClientRect(hwnd, &mut rc);
        rc.bottom - rc.top
    };
    // 计算滑块几何。
    let thumb_geom = || -> Option<(i32, i32, i32, i32)> {
        if edit.is_invalid() {
            return None;
        }
        let (first, total, visible) = log_scroll_metrics(edit);
        if total <= visible {
            return None; // 内容未超出，无需滑块。
        }
        let max_first = total - visible;
        let min_thumb = 24;
        let thumb_h = ((track_h * visible / total).max(min_thumb)).min(track_h);
        let span = track_h - thumb_h;
        let thumb_top = if max_first > 0 { span * first / max_first } else { 0 };
        Some((thumb_top, thumb_h, first, max_first))
    };
    match msg {
        WM_PAINT => {
            let mut ps = PAINTSTRUCT::default();
            let hdc = BeginPaint(hwnd, &mut ps);
            let mut rc = RECT::default();
            let _ = GetClientRect(hwnd, &mut rc);
            // 轨道：与日志框底色一致，消除割裂。
            let track = CreateSolidBrush(st.theme.control_bg);
            FillRect(hdc, &rc, track);
            let _ = DeleteObject(HGDIOBJ(track.0));
            if let Some((top, h, _, _)) = thumb_geom() {
                // 滑块：中性灰，留 2px 内边距形成细长圆角观感。
                let thumb_color = if st.theme.dark {
                    COLORREF(0x005A5A5A)
                } else {
                    COLORREF(0x00C0C0C0)
                };
                let br = CreateSolidBrush(thumb_color);
                let pad = 2;
                let tr = RECT {
                    left: rc.left + pad,
                    top: top + pad,
                    right: rc.right - pad,
                    bottom: top + h - pad,
                };
                let old = SelectObject(hdc, HGDIOBJ(br.0));
                let oldpen = SelectObject(hdc, HGDIOBJ(GetStockObject(NULL_PEN).0));
                let r = (rc.right - rc.left - pad * 2).min(tr.bottom - tr.top);
                let _ = RoundRect(hdc, tr.left, tr.top, tr.right, tr.bottom, r, r);
                SelectObject(hdc, oldpen);
                SelectObject(hdc, old);
                let _ = DeleteObject(HGDIOBJ(br.0));
            }
            let _ = EndPaint(hwnd, &ps);
            LRESULT(0)
        }
        WM_ERASEBKGND => LRESULT(1),
        WM_LBUTTONDOWN => {
            let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
            if let Some((top, h, _, _)) = thumb_geom() {
                if y >= top && y < top + h {
                    // 命中滑块：开始拖动。
                    st.sb_drag = true;
                    st.sb_drag_off = y - top;
                    SetCapture(hwnd);
                } else {
                    // 点击轨道空白：按页滚动。
                    let (_, _, visible) = log_scroll_metrics(edit);
                    let dir = if y < top { -visible } else { visible };
                    SendMessageW(edit, EM_LINESCROLL, WPARAM(0), LPARAM(dir as isize));
                    let _ = InvalidateRect(hwnd, None, FALSE);
                }
            }
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            if st.sb_drag {
                let y = ((lparam.0 >> 16) & 0xFFFF) as i16 as i32;
                if let Some((_, h, first, max_first)) = thumb_geom() {
                    let span = (track_h - h).max(1);
                    let new_top = (y - st.sb_drag_off).clamp(0, span);
                    let new_first = new_top * max_first / span;
                    let delta = new_first - first;
                    if delta != 0 {
                        SendMessageW(edit, EM_LINESCROLL, WPARAM(0), LPARAM(delta as isize));
                        let _ = InvalidateRect(hwnd, None, FALSE);
                    }
                }
            }
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            if st.sb_drag {
                st.sb_drag = false;
                let _ = ReleaseCapture();
            }
            LRESULT(0)
        }
        WM_MOUSEWHEEL => {
            let delta = ((wparam.0 >> 16) & 0xFFFF) as i16 as i32;
            let lines = -(delta / 120) * 3;
            SendMessageW(edit, EM_LINESCROLL, WPARAM(0), LPARAM(lines as isize));
            let _ = InvalidateRect(hwnd, None, FALSE);
            LRESULT(0)
        }
        WM_NCDESTROY => {
            let _ = RemovePropW(hwnd, w!("ChatputState"));
            DefWindowProcW(hwnd, msg, wparam, lparam)
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
        PCWSTR(to_wide(&localization::t("ChatPUT · 设置", "ChatPUT · Settings")).as_ptr()),
    );
}

/// 按目标客户区尺寸调整设置窗口（含标题栏/边框，按当前 DPI 换算），保持左上角不变。
unsafe fn resize_settings_client(hwnd: HWND, client_w: i32, client_h: i32, scale: f64) {
    let mut r = RECT { left: 0, top: 0, right: client_w, bottom: client_h };
    let style = WINDOW_STYLE(GetWindowLongPtrW(hwnd, GWL_STYLE) as u32);
    let ex = WINDOW_EX_STYLE(GetWindowLongPtrW(hwnd, GWL_EXSTYLE) as u32);
    let dpi = (scale * 96.0).round() as u32;
    let _ = AdjustWindowRectExForDpi(&mut r, style, FALSE, ex, dpi);
    let _ = SetWindowPos(
        hwnd,
        None,
        0,
        0,
        r.right - r.left,
        r.bottom - r.top,
        SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE,
    );
}


unsafe fn build_settings(st: &mut UiState, hwnd: HWND) {
    // 按设置窗口所在显示器 DPI 重建专属字体（Per-Monitor 动态适配，独立于 popup）。
    ensure_set_fonts(st, dpi_for_window(hwnd));
    let s = st.set_scale;
    let nf = st.sf_normal;
    let lf = st.sf_label;
    let sf = st.sf_small;
    let px = |v: f64| (v * s) as i32;

    // ── 布局常量（逻辑像素 × set_scale）──
    let margin = px(12.0); // 窗口边缘到 tab
    let pad = px(16.0); // tab 页内 padding
    let row_gap = px(14.0); // 选项行间距
    let note_gap = px(4.0); // 控件到描述间距
    let header_gap = px(12.0); // section header 到首行
    let label_w = px(96.0); // 标签列宽
    let label_gap = px(10.0); // 标签到控件列间距
    let combo_sw = px(120.0); // 小下拉宽
    let qual_w = px(150.0); // 画质下拉宽
    let chk_w = px(18.0); // checkbox 宽
    let edit_w = px(130.0); // 小编辑框宽（端口）
    let btn_w = px(140.0); // 执行按钮宽
    let clr_w = px(96.0); // 清空按钮宽

    // ── 控件高度（按字体动态推导，适配字体/DPI 变化）──
    let th = font_text_height(nf);
    let label_h = font_text_height(lf) + px(4.0);
    let small_h = font_text_height(sf);
    let edit_h = th + px(8.0);
    let btn_h = th + px(14.0);
    let badge_h = small_h + px(4.0);
    let heading_h = font_text_height(st.sf_heading) + px(2.0);

    // 探测系统下拉框「闭合高度」（随字体/DPI 变化）作为行高基准，修正行间距。
    let probe = child(
        hwnd, w!("COMBOBOX"), "",
        WS_TABSTOP.0 | CBS_DROPDOWNLIST | CBS_HASSTRINGS,
        -400, -400, combo_sw, px(200.0), 9990, nf,
    );
    let mut pr = RECT::default();
    let _ = GetWindowRect(probe, &mut pr);
    let combo_h = (pr.bottom - pr.top).max(th + px(6.0));
    let _ = DestroyWindow(probe);

    // ── 第一遍：固定客户区宽度，高度给上限，建立 Tab 与 display area ──
    let client_w = px(500.0);
    resize_settings_client(hwnd, client_w, px(560.0), s);
    let mut cl = RECT::default();
    let _ = GetClientRect(hwnd, &mut cl);
    let win_w = cl.right;
    let prov_h = cl.bottom;

    let prov_tab_h = prov_h - 2 * margin - btn_h - margin;
    let tab = child(
        hwnd, w!("SysTabControl32"), "", WS_CLIPSIBLINGS.0,
        margin, margin, win_w - 2 * margin, prov_tab_h, ID_TAB, nf,
    );
    st.tab = tab;
    if st.theme.dark {
        apply_control_theme(tab, true);
        let prev = SetWindowLongPtrW(tab, GWLP_WNDPROC, tab_dark_wndproc as *const () as isize);
        SetWindowLongPtrW(tab, GWLP_USERDATA, prev);
        let hwnd_ptr = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
        let _ = SetPropW(tab, w!("ChatputState"), HANDLE(hwnd_ptr as *mut c_void));
    }
    st.tab_theme = OpenThemeData(hwnd, w!("TAB"));
    let host = hwnd;
    tab_insert(tab, 0, &localization::t("通用", "General"));
    tab_insert(tab, 1, &localization::t("远程桌面", "Screen"));
    tab_insert(tab, 2, &localization::t("内置服务", "Built-in"));
    tab_insert(tab, 3, &localization::t("外部服务", "External"));
    tab_insert(tab, 4, &localization::t("日志", "Logs"));

    // 用 TCM_ADJUSTRECT 取 Tab 真实 display area（含系统内部边框，DPI 安全）。
    let mut tab_wr = RECT::default();
    let _ = GetWindowRect(st.tab, &mut tab_wr);
    let mut parent_pt = POINT { x: 0, y: 0 };
    let _ = ClientToScreen(host, &mut parent_pt);
    tab_wr.left -= parent_pt.x;
    tab_wr.top -= parent_pt.y;
    tab_wr.right -= parent_pt.x;
    tab_wr.bottom -= parent_pt.y;
    let mut display_rc = tab_wr;
    SendMessageW(st.tab, TCM_ADJUSTRECT, WPARAM(0), LPARAM(&mut display_rc as *mut RECT as isize));

    let content_x = display_rc.left + pad;
    let content_y = display_rc.top + pad;
    let content_w = (display_rc.right - pad) - content_x;
    let col_x = content_x + label_w + label_gap;
    let ctrl_w = content_w - label_w - label_gap;
    let header_w = content_w;
    let lab_off_combo = ((combo_h - label_h) / 2).max(0);
    let lab_off_edit = ((edit_h - label_h) / 2).max(0);

    // ── 文案与动态描述高度（自动换行测量，适配字体/语言变化）──
    use crate::app::settings::ScreenCodec;
    let t = localization::t;
    let gen_sub = t("语言与启动选项。", "Language and startup options.");
    let transport_note_h = measure_text_height(sf, ctrl_w, &TransportMode::Webrtc.note())
        .max(measure_text_height(sf, ctrl_w, &TransportMode::Websocket.note()));
    let scr_sub = t(
        "远程桌面的采集、编码与交互参数。",
        "Capture, encoding and interaction settings for remote screen.",
    );
    let codec_note_h = [ScreenCodec::H264, ScreenCodec::Vp8, ScreenCodec::Vp9]
        .iter()
        .map(|c| measure_text_height(sf, ctrl_w, &c.note()))
        .max()
        .unwrap_or(small_h);
    let res_note = t(
        "缩小桌面图像以节省带宽，手机端自动上采样填满画面。",
        "Downscales the desktop image to save bandwidth. The phone upscales to fill the view.",
    );
    let res_note_h = measure_text_height(sf, ctrl_w, &res_note);
    let bi_sub = t(
        "在本机运行信令服务器，手机与电脑处于同一局域网时使用。",
        "Run the signaling server locally; use it when phone and PC are on the same LAN.",
    );
    let detected = network_info::primary_lan_ipv4()
        .unwrap_or_else(|| t("未找到局域网地址", "no LAN address"));
    let detected_text = t("自动探测：", "Detected: ") + &detected;
    let detected_h = measure_text_height(sf, ctrl_w, &detected_text);
    let ex_sub = t(
        "连接已部署在公网的信令服务器，跨网络远程使用。",
        "Connect to a signaling server on the public internet for remote use.",
    );
    let ext_note = t(
        "二维码将广播此地址，供手机连接。",
        "The QR code broadcasts this address for the phone.",
    );
    let ext_note_h = measure_text_height(sf, ctrl_w, &ext_note);

    // ── 计算最高 tab 的内容高度，据此自适应客户区高度 ──
    let hdr = |sub_h: i32| heading_h + px(4.0) + sub_h;
    let gen_h = hdr(measure_text_height(sf, header_w, &gen_sub))
        + header_gap
        + (combo_h + row_gap) * 2
        + (combo_h + note_gap + transport_note_h + row_gap)
        + combo_h;
    let scr_h = hdr(measure_text_height(sf, header_w, &scr_sub))
        + header_gap
        + (combo_h + note_gap + codec_note_h + row_gap)
        + (combo_h + row_gap)
        + (combo_h + note_gap + res_note_h + row_gap)
        + (combo_h + row_gap)
        + combo_h;
    let bi_h = hdr(measure_text_height(sf, header_w, &bi_sub))
        + header_gap
        + (badge_h + row_gap)
        + (edit_h + row_gap)
        + (edit_h + note_gap + detected_h);
    let ex_h = hdr(measure_text_height(sf, header_w, &ex_sub))
        + header_gap
        + (badge_h + row_gap)
        + (edit_h + note_gap + ext_note_h);
    let content_h = gen_h.max(scr_h).max(bi_h).max(ex_h);

    // 按钮区位于 Tab 页内部底端（对齐 macOS：Spacer 将按钮顶到 tab 内容底部）。
    let btn_strip = row_gap + btn_h;

    // ── 第二遍：按内容收缩窗口，重排 Tab（按钮含在 Tab 页内）──
    let tab_bottom = content_y + content_h + btn_strip + pad + px(4.0);
    let tab_h = tab_bottom - margin;
    let client_h = tab_bottom + margin;
    resize_settings_client(hwnd, client_w, client_h, s);
    let mut cl2 = RECT::default();
    let _ = GetClientRect(hwnd, &mut cl2);
    let win_w = cl2.right;
    let _ = SetWindowPos(
        st.tab, None, margin, margin, win_w - 2 * margin, tab_h,
        SWP_NOZORDER | SWP_NOACTIVATE,
    );
    // Tab 页内的按钮基线与右边界（content 坐标系，位于 Tab 显示区内部）。
    let btn_y = content_y + content_h + row_gap;
    let content_right = content_x + content_w;

    // ═══════════ 0. 通用 ═══════════
    let mut y = content_y;
    let gh = section_header(st, 0, host, content_x, y, header_w, &t("通用", "General"), &gen_sub);
    y += gh + header_gap;

    add_label(st, 0, host, content_x, y + lab_off_combo, label_w, &t("开机自动运行", "Launch at login"), lf);
    st.chk_launch = add_ctrl(st, 0, host, w!("BUTTON"), "",
        WS_TABSTOP.0 | BS_AUTOCHECKBOX, col_x, y, chk_w, combo_h, ID_CHK_LAUNCH, nf);
    if st.settings.launch_at_login { SendMessageW(st.chk_launch, BM_SETCHECK, WPARAM(1), LPARAM(0)); }
    y += combo_h + row_gap;

    add_label(st, 0, host, content_x, y + lab_off_combo, label_w, &t("自动保存房间", "Auto-save room"), lf);
    st.chk_auto_room = add_ctrl(st, 0, host, w!("BUTTON"), "",
        WS_TABSTOP.0 | BS_AUTOCHECKBOX, col_x, y, chk_w, combo_h, ID_CHK_AUTO_ROOM, nf);
    if st.settings.auto_save_room_id { SendMessageW(st.chk_auto_room, BM_SETCHECK, WPARAM(1), LPARAM(0)); }
    y += combo_h + row_gap;

    add_label(st, 0, host, content_x, y + lab_off_combo, label_w, &t("传输模式", "Transport"), lf);
    st.cb_transport = add_combo(st, 0, host, col_x, y, ctrl_w, ID_CB_TRANSPORT, nf);
    combo_add(st.cb_transport, &TransportMode::Webrtc.label());
    combo_add(st.cb_transport, &TransportMode::Websocket.label());
    combo_set(st.cb_transport, if st.settings.transport == TransportMode::Websocket { 1 } else { 0 });
    add_label_h(st, 0, host, col_x, y + combo_h + note_gap, ctrl_w, transport_note_h, &st.settings.transport.note(), sf);
    y += combo_h + note_gap + transport_note_h + row_gap;

    add_label(st, 0, host, content_x, y + lab_off_combo, label_w, &t("语言", "Language"), lf);
    st.cb_language = add_combo(st, 0, host, col_x, y, ctrl_w, ID_CB_LANGUAGE, nf);
    combo_add(st.cb_language, &AppLanguage::System.label());
    combo_add(st.cb_language, &AppLanguage::Zh.label());
    combo_add(st.cb_language, &AppLanguage::En.label());
    combo_set(st.cb_language, match st.settings.language { AppLanguage::System => 0, AppLanguage::Zh => 1, AppLanguage::En => 2 });

    // ═══════════ 1. 远程桌面 ═══════════
    let scr = 1;
    let mut y = content_y;
    let sh = section_header(st, scr, host, content_x, y, header_w, &t("远程桌面", "Screen"), &scr_sub);
    y += sh + header_gap;

    add_label(st, scr, host, content_x, y + lab_off_combo, label_w, &t("优先编码", "Preferred codec"), lf);
    st.cb_codec = add_combo(st, scr, host, col_x, y, combo_sw, ID_CB_CODEC, nf);
    let codec_items = [ScreenCodec::H264, ScreenCodec::Vp8, ScreenCodec::Vp9];
    let mut c = 0; for (i, cd) in codec_items.iter().enumerate() { combo_add(st.cb_codec, &cd.label()); if (st.settings.screen_codec as usize) == (*cd as usize) { c = i; } }
    combo_set(st.cb_codec, c);
    add_label_h(st, scr, host, col_x, y + combo_h + note_gap, ctrl_w, codec_note_h, &st.settings.screen_codec.note(), sf);
    y += combo_h + note_gap + codec_note_h + row_gap;

    add_label(st, scr, host, content_x, y + lab_off_combo, label_w, &t("采集帧率", "FPS"), lf);
    st.cb_fps = add_combo(st, scr, host, col_x, y, combo_sw, ID_CB_FPS, nf);
    let fps_items = [crate::app::settings::ScreenFPS::Fps12, crate::app::settings::ScreenFPS::Fps18, crate::app::settings::ScreenFPS::Fps24, crate::app::settings::ScreenFPS::Fps30];
    let mut c = 1; for (i, fp) in fps_items.iter().enumerate() { combo_add(st.cb_fps, &fp.label()); if st.settings.screen_fps.value() == fp.value() { c = i; } }
    combo_set(st.cb_fps, c);
    y += combo_h + row_gap;

    add_label(st, scr, host, content_x, y + lab_off_combo, label_w, &t("输出分辨率", "Resolution"), lf);
    st.cb_scale = add_combo(st, scr, host, col_x, y, combo_sw, ID_CB_SCALE, nf);
    let scale_items = [crate::app::settings::ScreenScale::P100, crate::app::settings::ScreenScale::P80, crate::app::settings::ScreenScale::P75, crate::app::settings::ScreenScale::P60, crate::app::settings::ScreenScale::P50];
    let mut c = 0; for (i, sc) in scale_items.iter().enumerate() { combo_add(st.cb_scale, &sc.label()); if (st.settings.screen_scale as usize) == (*sc as usize) { c = i; } }
    combo_set(st.cb_scale, c);
    add_label_h(st, scr, host, col_x, y + combo_h + note_gap, ctrl_w, res_note_h, &res_note, sf);
    y += combo_h + note_gap + res_note_h + row_gap;

    add_label(st, scr, host, content_x, y + lab_off_combo, label_w, &t("画质偏好", "Quality"), lf);
    st.cb_quality = add_combo(st, scr, host, col_x, y, qual_w, ID_CB_QUALITY, nf);
    let qual_items = [crate::app::settings::ScreenQuality::Disabled, crate::app::settings::ScreenQuality::MaintainResolution, crate::app::settings::ScreenQuality::Balanced];
    let mut c = 0; for (i, q) in qual_items.iter().enumerate() { combo_add(st.cb_quality, &q.label()); if (st.settings.screen_quality as usize) == (*q as usize) { c = i; } }
    combo_set(st.cb_quality, c);
    y += combo_h + row_gap;

    add_label(st, scr, host, content_x, y + lab_off_combo, label_w, &t("固定码率", "Fixed bitrate"), lf);
    st.chk_bitrate = add_ctrl(st, scr, host, w!("BUTTON"), "",
        WS_TABSTOP.0 | BS_AUTOCHECKBOX, col_x, y, chk_w, combo_h, ID_CHK_BITRATE, nf);
    if st.settings.disable_dynamic_bitrate { SendMessageW(st.chk_bitrate, BM_SETCHECK, WPARAM(1), LPARAM(0)); }
    add_label_h(st, scr, host, col_x + chk_w + note_gap, y + (combo_h - small_h) / 2, ctrl_w - chk_w - note_gap, small_h,
        &t("关闭自适应，首帧即清晰", "Disable adaptive bitrate for sharp first frames."), sf);

    // ═══════════ 2. 内置服务 ═══════════
    let mut y = content_y;
    let bh = section_header(st, 2, host, content_x, y, header_w, &t("内置服务（局域网）", "Built-in (LAN)"), &bi_sub);
    y += bh + header_gap;
    add_mode_badge(st, 2, host, content_x, y, st.settings.mode == SignalingMode::BuiltIn);
    y += badge_h + row_gap;

    add_label(st, 2, host, content_x, y + lab_off_edit, label_w, &t("监听端口", "Port"), lf);
    st.ed_port = add_edit(st, 2, host, col_x, y, edit_w, ID_ED_PORT, nf);
    set_text(st.ed_port, &st.settings.listen_port.to_string());
    y += edit_h + row_gap;

    add_label(st, 2, host, content_x, y + lab_off_edit, label_w, &t("对外 IP", "Host IP"), lf);
    st.ed_ip = add_edit(st, 2, host, col_x, y, ctrl_w, ID_ED_IP, nf);
    set_cue(st.ed_ip, &t("留空自动探测", "Auto-detect if empty"));
    set_text(st.ed_ip, &st.settings.ip_override);
    y += edit_h + note_gap;
    add_label_h(st, 2, host, col_x, y, ctrl_w, detected_h, &detected_text, sf);

    // ═══════════ 3. 外部服务 ═══════════
    let mut y = content_y;
    let eh2 = section_header(st, 3, host, content_x, y, header_w, &t("外部服务（公网远程）", "External (remote)"), &ex_sub);
    y += eh2 + header_gap;
    add_mode_badge(st, 3, host, content_x, y, st.settings.mode == SignalingMode::External);
    y += badge_h + row_gap;

    add_label(st, 3, host, content_x, y + lab_off_edit, label_w, &t("信令地址", "Address"), lf);
    st.ed_url = add_edit(st, 3, host, col_x, y, ctrl_w, ID_ED_URL, nf);
    set_cue(st.ed_url, "ws://example.com:8080");
    set_text(st.ed_url, &st.settings.external_url);
    y += edit_h + note_gap;
    add_label_h(st, 3, host, col_x, y, ctrl_w, ext_note_h, &ext_note, sf);

    // ═══════════ Tab 页内底部按钮区（对齐 macOS saveBar，位于 Tab 区域内）═══════════
    add_ctrl(st, 2, host, w!("BUTTON"), &t("保存并应用", "Save & Apply"),
        WS_TABSTOP.0, content_right - btn_w, btn_y, btn_w, btn_h, ID_BTN_SAVE_BUILTIN, nf);
    st.btn_save_external = add_ctrl(st, 3, host, w!("BUTTON"), &external_save_label(&st.settings.external_url),
        WS_TABSTOP.0, content_right - btn_w, btn_y, btn_w, btn_h, ID_BTN_SAVE_EXTERNAL, nf);
    add_ctrl(st, 4, host, w!("BUTTON"), &t("清空", "Clear"),
        WS_TABSTOP.0, content_right - clr_w, btn_y, clr_w, btn_h, ID_BTN_CLEAR, nf);

    // ═══════════ 4. 日志 ═══════════
    let log_x = content_x;
    let log_y = content_y;
    let log_w = content_w;
    let log_bottom = btn_y - row_gap;
    let log_h = (log_bottom - log_y).max(px(60.0));
    st.ed_log = child(host, w!("EDIT"), "",
        WS_TABSTOP.0 | WS_BORDER.0 | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL | WS_VSCROLL.0,
        log_x, log_y, log_w, log_h, ID_ED_LOG, sf);
    if st.theme.dark { allow_dark_for_window(st.ed_log, true); }
    st.tab_ctrls.push((4, st.ed_log));
    st.log_sb = HWND(null_mut());
    refresh_log(st);

    apply_tab_visibility(st, 0);
}


unsafe fn add_mode_badge(st: &mut UiState, tab: i32, parent: HWND, x: i32, y: i32, active: bool) {
    let s = st.set_scale;
    let off2 = (2.0 * s) as i32;
    let d14 = (14.0 * s) as i32;
    let gap18 = (18.0 * s) as i32;
    // 圆点：生效=绿色，未启用=灰色（对齐 macOS modeBadge）。
    let dot_color = if active { STATE_CONNECTED } else { st.theme.badge_idle };
    let dot = add_ctrl(st, tab, parent, w!("STATIC"), "\u{E91F}", SS_LEFT, x, y + off2, d14, d14, 0, st.sf_dot);
    st.colored_statics.push((dot, dot_color));
    let text = if active {
        localization::t("当前生效模式", "Active mode")
    } else {
        localization::t("未启用（保存后切换到此模式）", "Inactive (save to switch here)")
    };
    add_label(st, tab, parent, x + gap18, y, (360.0 * s) as i32, &text, st.sf_small);
}

unsafe fn apply_tab_visibility(st: &mut UiState, idx: i32) {
    st.cur_tab = idx;
    for (t, h) in &st.tab_ctrls {
        let _ = ShowWindow(*h, if *t == idx { SW_SHOW } else { SW_HIDE });
    }
    if idx == 4 {
        refresh_log(st);
    }
}

unsafe fn refresh_log(st: &mut UiState) {
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

    if !st.log_sb.is_invalid() {
        let _ = InvalidateRect(st.log_sb, None, FALSE);
    }
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
        ID_CHK_AUTO_ROOM if code == BN_CLICKED => {
            let on = SendMessageW(st.chk_auto_room, BM_GETCHECK, WPARAM(0), LPARAM(0)).0 == 1;
            st.settings.auto_save_room_id = on;
            st.settings.save();
        }
        // 画面设置（即时保存，不重启）
        ID_CB_FPS if code == CBN_SELCHANGE => {
            use crate::app::settings::ScreenFPS;
            st.settings.screen_fps = match combo_get(st.cb_fps) {
                0 => ScreenFPS::Fps12,
                1 => ScreenFPS::Fps18,
                2 => ScreenFPS::Fps24,
                3 => ScreenFPS::Fps30,
                _ => ScreenFPS::Fps18,
            };
            st.settings.save();
        }
        ID_CB_CODEC if code == CBN_SELCHANGE => {
            use crate::app::settings::ScreenCodec;
            st.settings.screen_codec = match combo_get(st.cb_codec) {
                0 => ScreenCodec::H264,
                1 => ScreenCodec::Vp8,
                2 => ScreenCodec::Vp9,
                _ => ScreenCodec::H264,
            };
            st.settings.save();
        }
        ID_CB_SCALE if code == CBN_SELCHANGE => {
            use crate::app::settings::ScreenScale;
            st.settings.screen_scale = match combo_get(st.cb_scale) {
                0 => ScreenScale::P100,
                1 => ScreenScale::P80,
                2 => ScreenScale::P75,
                3 => ScreenScale::P60,
                4 => ScreenScale::P50,
                _ => ScreenScale::P100,
            };
            st.settings.save();
        }
        ID_CB_QUALITY if code == CBN_SELCHANGE => {
            use crate::app::settings::ScreenQuality;
            st.settings.screen_quality = match combo_get(st.cb_quality) {
                0 => ScreenQuality::Disabled,
                1 => ScreenQuality::MaintainResolution,
                2 => ScreenQuality::Balanced,
                _ => ScreenQuality::Disabled,
            };
            st.settings.save();
        }
        ID_CHK_BITRATE if code == BN_CLICKED => {
            let on = SendMessageW(st.chk_bitrate, BM_GETCHECK, WPARAM(0), LPARAM(0)).0 == 1;
            st.settings.disable_dynamic_bitrate = on;
            st.settings.save();
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
    if st.theme.dark {
        apply_control_theme(h, true);
    }
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
    let lh = font_text_height(font) + (4.0 * st.set_scale) as i32;
    add_ctrl(st, tab, parent, w!("STATIC"), text, SS_LEFT, x, y, w, lh, 0, font)
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
/// 返回区块总高度（标题 + 间距 + 自动换行的描述）。
unsafe fn section_header(st: &mut UiState, tab: i32, parent: HWND, x: i32, y: i32, w: i32, title: &str, subtitle: &str) -> i32 {
    let s = st.set_scale;
    let title_h = font_text_height(st.sf_heading) + (2.0 * s) as i32;
    let gap = (4.0 * s) as i32;
    let sub_h = measure_text_height(st.sf_small, w, subtitle);
    add_label_h(st, tab, parent, x, y, w, title_h, title, st.sf_heading);
    add_label_h(st, tab, parent, x, y + title_h + gap, w, sub_h, subtitle, st.sf_small);
    title_h + gap + sub_h
}

#[allow(clippy::too_many_arguments)]
unsafe fn add_combo(st: &mut UiState, tab: i32, parent: HWND, x: i32, y: i32, w: i32, id: usize, font: HFONT) -> HWND {
    let drop_h = (220.0 * st.set_scale) as i32;
    let h = add_ctrl(
        st, tab, parent, w!("COMBOBOX"), "",
        WS_TABSTOP.0 | WS_VSCROLL.0 | CBS_DROPDOWNLIST | CBS_HASSTRINGS,
        x, y, w, drop_h, id, font,
    );
    if st.theme.dark {
        // 下拉框需要 CFD（Combobox Flat Dropdown）主题，列表与按钮才会变暗。
        allow_dark_for_window(h, true);
        let _ = SetWindowTheme(h, w!("DarkMode_CFD"), None);
    }
    // 浅色模式不调 SetWindowTheme，保持系统默认主题（含可见边框）。
    h
}

#[allow(clippy::too_many_arguments)]
unsafe fn add_edit(st: &mut UiState, tab: i32, parent: HWND, x: i32, y: i32, w: i32, id: usize, font: HFONT) -> HWND {
    let eh = font_text_height(font) + (8.0 * st.set_scale) as i32;
    add_ctrl(
        st, tab, parent, w!("EDIT"), "",
        WS_TABSTOP.0 | WS_BORDER.0 | ES_AUTOHSCROLL,
        x, y, w, eh, id, font,
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

/// 销毁设置窗口专属字体。
unsafe fn destroy_set_fonts(st: &mut UiState) {
    for f in [st.sf_heading, st.sf_normal, st.sf_label, st.sf_small, st.sf_dot] {
        if !f.is_invalid() {
            let _ = DeleteObject(HGDIOBJ(f.0));
        }
    }
    st.sf_heading = HFONT(null_mut());
    st.sf_normal = HFONT(null_mut());
    st.sf_label = HFONT(null_mut());
    st.sf_small = HFONT(null_mut());
    st.sf_dot = HFONT(null_mut());
}

/// 按设置窗口当前 DPI 重建专属字体（独立于 popup，避免相互影响）。
unsafe fn ensure_set_fonts(st: &mut UiState, scale: f64) {
    destroy_set_fonts(st);
    st.set_scale = scale;
    st.sf_heading = make_font(-(15.0 * scale) as i32, 700);
    st.sf_normal = make_font(-(14.0 * scale) as i32, 400);
    st.sf_label = make_font(-(13.5 * scale) as i32, 400);
    st.sf_small = make_font(-(12.0 * scale) as i32, 400);
    st.sf_dot = make_icon_font(-(11.0 * scale) as i32);
}

/// 字体单行高度（tmHeight + tmExternalLeading），用于按字体动态推导控件高度。
unsafe fn font_text_height(font: HFONT) -> i32 {
    let hdc = GetDC(None);
    let old = SelectObject(hdc, HGDIOBJ(font.0));
    let mut tm = TEXTMETRICW::default();
    let _ = GetTextMetricsW(hdc, &mut tm);
    SelectObject(hdc, old);
    ReleaseDC(None, hdc);
    (tm.tmHeight + tm.tmExternalLeading).max(1)
}

/// 给定字体与可用宽度，自动换行测量文本绘制高度（动态适配字体/换行变化）。
unsafe fn measure_text_height(font: HFONT, width: i32, text: &str) -> i32 {
    if text.is_empty() {
        return 0;
    }
    let hdc = GetDC(None);
    let old = SelectObject(hdc, HGDIOBJ(font.0));
    let mut wide: Vec<u16> = text.encode_utf16().collect();
    let mut r = RECT { left: 0, top: 0, right: width.max(1), bottom: 0 };
    DrawTextW(hdc, &mut wide, &mut r, DT_CALCRECT | DT_WORDBREAK | DT_LEFT);
    SelectObject(hdc, old);
    ReleaseDC(None, hdc);
    (r.bottom - r.top).max(1)
}

/// 指定窗口所在显示器的 DPI 缩放系数（dpi / 96），用于 Per-Monitor 动态适配。
unsafe fn dpi_for_window(hwnd: HWND) -> f64 {
    let dpi = GetDpiForWindow(hwnd);
    if dpi == 0 {
        get_dpi_scale()
    } else {
        (dpi as f64 / 96.0).max(1.0)
    }
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
