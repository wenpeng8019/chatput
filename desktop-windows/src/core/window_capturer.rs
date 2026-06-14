//! 远程窗口画面采集器（2.0）。
//!
//! 用 GDI PrintWindow 采集单个窗口的完整画面，再在每帧上：
//! 1. 裁剪出当前视口子区域，输出 RGBA 像素缓冲，喂给 WebRTC 视频轨（主画面）；
//! 2. 周期性把整窗降采样为小 JPEG，作为手机端「小地图」缩略图。
//!
//! 视口平移通过线程间共享的原子变量即时生效，不重启采集流。
//! 对标 macOS 的 WindowCapturer.swift。

use crate::core::config;
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicIsize, Ordering};
use std::sync::mpsc::{self, Sender};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

use windows::Win32::Foundation::{BOOL, HWND, LPARAM, RECT, WPARAM};
use windows::Win32::Graphics::Gdi::{
    BitBlt, CreateCompatibleBitmap, CreateCompatibleDC, DeleteDC, DeleteObject,
    GetDC, GetDeviceCaps, GetDIBits, ReleaseDC, SelectObject, SRCCOPY,
    BITMAPINFO, BITMAPINFOHEADER, DIB_RGB_COLORS, HDC, HBITMAP, LOGPIXELSX,
};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumWindows, GetWindowRect, GetWindowTextLengthW, SendMessageW,
    GetWindowTextW, GetWindowThreadProcessId, IsIconic, IsWindowVisible,
};

// WM_PRINT 消息使用的 PRF (Print Render Format) 标志。
const WM_PRINT: u32 = 0x0318;
const PRF_CLIENT: usize = 0x0004;     // 客户区
const PRF_CHILDREN: usize = 0x0010;   // 可见子窗口
const PRF_ERASEBKGND: usize = 0x0008; // 先擦除背景
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_FORMAT,
    PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE,
};
use windows::Win32::Foundation::CloseHandle;

/// 采集器对外输出的事件。
pub enum CapturerEvent {
    /// 视口画面 RGBA 原始像素（width, height, data, timestamp_ns）。
    Frame(u32, u32, Vec<u8>, i64),
    /// 整窗缩略图 JPEG 数据。
    Thumbnail(Vec<u8>),
    /// 元数据：窗口逻辑尺寸 (w, h)、生效视口 (x, y, w, h)、backing scale。
    Meta(i32, i32, i32, i32, i32, i32, f64),
    /// 窗口几何信息就绪，供 PointerInjector 初始化。
    WindowReady(RECT, f64),
    /// 采集错误（如窗口未找到）。
    Error(String),
    /// 日志行。
    Log(String),
}

/// 采集线程与主线程间的共享状态：视口、运行标志、窗口句柄。
struct CaptureShared {
    vp_x: AtomicI32,
    vp_y: AtomicI32,
    vp_w: AtomicI32,
    vp_h: AtomicI32,
    running: AtomicBool,
    hwnd_raw: AtomicIsize,
}

impl CaptureShared {
    fn new(vp_w: i32, vp_h: i32) -> Self {
        CaptureShared {
            vp_x: AtomicI32::new(0),
            vp_y: AtomicI32::new(0),
            vp_w: AtomicI32::new(vp_w),
            vp_h: AtomicI32::new(vp_h),
            running: AtomicBool::new(true),
            hwnd_raw: AtomicIsize::new(0),
        }
    }
}

/// 采集线程内部状态（GDI 资源 + 帧缓存）。
struct CaptureState {
    hwnd: HWND,
    session_id: String,
    /// 窗口像素尺寸。
    pixel_w: i32,
    pixel_h: i32,
    /// backing scale（DPI / 96）。
    scale: f64,
    /// 窗口屏幕坐标（用于 BitBlt 兜底）。
    win_left: i32,
    win_top: i32,
    /// 帧间隔。
    frame_interval_ms: u64,
    /// GDI 资源：内存 DC + 兼容位图。
    mem_dc: HDC,
    mem_bmp: HBITMAP,
    /// 全窗 RGBA 像素缓存（用于视口裁剪）。
    full_rgba: Vec<u8>,
    /// 上次缩略图时间。
    last_thumb: Instant,
    /// 诊断：首帧屏幕 (0,0) 采样完成标志。
    diag_done: bool,
    /// 待输出的诊断消息。
    pending_diag: Option<String>,
}

/// 窗口采集器：内部起一个线程做定时采集。
pub struct WindowCapturer {
    tx: Sender<CapturerEvent>,
    shared: Arc<CaptureShared>,
}

impl WindowCapturer {
    pub fn new() -> Self {
        let (tx, _rx) = mpsc::channel();
        WindowCapturer {
            tx,
            shared: Arc::new(CaptureShared::new(0, 0)),
        }
    }

    /// 取出事件接收端（协调器使用）。
    pub fn take_receiver(&mut self) -> mpsc::Receiver<CapturerEvent> {
        let (tx, rx) = mpsc::channel();
        self.tx = tx;
        rx
    }

    /// 获取采集线程的 HWND（供 PointerInjector 使用）。
    pub fn capture_hwnd(&self) -> Option<HWND> {
        let raw = self.shared.hwnd_raw.load(Ordering::Relaxed);
        if raw == 0 {
            None
        } else {
            Some(HWND(raw as *mut _))
        }
    }

    /// 按 app 名 + 窗口标题匹配窗口并开始采集。
    pub fn start(
        &self,
        session_id: &str,
        app: &str,
        title: &str,
        viewport_w: i32,
        viewport_h: i32,
        fps: u32,
    ) {
        // 先停止前一条采集流。
        self.shared.running.store(false, Ordering::SeqCst);

        let session_id = session_id.to_string();
        let app = app.to_string();
        let title = title.to_string();
        let tx = self.tx.clone();
        let shared = Arc::clone(&self.shared);
        let frame_interval_ms = if fps > 0 { 1000 / fps as u64 } else { 55 };

        // 重置共享状态。
        shared.vp_x.store(0, Ordering::SeqCst);
        shared.vp_y.store(0, Ordering::SeqCst);
        shared.vp_w.store(viewport_w.max(1), Ordering::SeqCst);
        shared.vp_h.store(viewport_h.max(1), Ordering::SeqCst);
        shared.running.store(true, Ordering::SeqCst);
        shared.hwnd_raw.store(0, Ordering::SeqCst);

        thread::spawn(move || {
            let hwnd = match find_window(&app, &title) {
                Some(h) => h,
                None => {
                    shared.running.store(false, Ordering::SeqCst);
                    let _ = tx.send(CapturerEvent::Error(format!(
                        "未匹配到窗口 {} - {}", app, title
                    )));
                    let _ = tx.send(CapturerEvent::Log(format!(
                        "窗口采集：未匹配到窗口 {} - {}", app, title
                    )));
                    return;
                }
            };
            shared.hwnd_raw.store(hwnd.0 as isize, Ordering::SeqCst);

            // 获取窗口像素尺寸和 DPI。
            let mut rect = RECT::default();
            if unsafe { GetWindowRect(hwnd, &mut rect) }.is_err() {
                shared.running.store(false, Ordering::SeqCst);
                let _ = tx.send(CapturerEvent::Error("无法获取窗口尺寸".to_string()));
                return;
            }
            let hdc = unsafe { GetDC(hwnd) };
            let dpi = if hdc.is_invalid() {
                96
            } else {
                let d = unsafe { GetDeviceCaps(hdc, LOGPIXELSX) };
                unsafe { ReleaseDC(hwnd, hdc) };
                d
            };
            let scale = dpi as f64 / 96.0;
            let pixel_w = ((rect.right - rect.left) as f64 * scale).round() as i32;
            let pixel_h = ((rect.bottom - rect.top) as f64 * scale).round() as i32;

            if pixel_w < 2 || pixel_h < 2 {
                shared.running.store(false, Ordering::SeqCst);
                let _ = tx.send(CapturerEvent::Error("窗口太小".to_string()));
                return;
            }

            let _ = tx.send(CapturerEvent::WindowReady(rect, scale));
            let _ = tx.send(CapturerEvent::Log(format!(
                "窗口采集开始：{} - {} [{}x{}] scale={:.1}",
                app, title, pixel_w, pixel_h, scale
            )));

            // 创建 GDI 资源。
            let screen_dc = unsafe { GetDC(hwnd) };
            let mem_dc = unsafe { CreateCompatibleDC(screen_dc) };
            if mem_dc.is_invalid() {
                shared.running.store(false, Ordering::SeqCst);
                let _ = tx.send(CapturerEvent::Error("创建内存 DC 失败".to_string()));
                unsafe { ReleaseDC(hwnd, screen_dc) };
                return;
            }
            let mem_bmp = unsafe { CreateCompatibleBitmap(screen_dc, pixel_w, pixel_h) };
            if mem_bmp.is_invalid() {
                shared.running.store(false, Ordering::SeqCst);
                let _ = tx.send(CapturerEvent::Error("创建位图失败".to_string()));
                unsafe { ReleaseDC(hwnd, screen_dc); }
                let _ = unsafe { DeleteDC(mem_dc) };
                return;
            }
            unsafe { ReleaseDC(hwnd, screen_dc); }
            let _old = unsafe { SelectObject(mem_dc, mem_bmp) };

            let mut state = CaptureState {
                hwnd,
                session_id,
                pixel_w,
                pixel_h,
                scale,
                win_left: rect.left,
                win_top: rect.top,
                frame_interval_ms,
                mem_dc,
                mem_bmp,
                full_rgba: vec![0u8; (pixel_w * pixel_h * 4) as usize],
                last_thumb: Instant::now(),
                diag_done: false,
                pending_diag: None,
            };

            let mut skip_count: u64 = 0;
            let mut frame_count: u64 = 0;

            loop {
                if !shared.running.load(Ordering::SeqCst) {
                    break;
                }

                let start = Instant::now();

                match capture_frame(&mut state, &shared) {
                    Ok(Some(frame)) => {
                        if skip_count > 0 || frame_count == 0 {
                            let nz = frame.data.chunks(4).take(2000)
                                .filter(|p| p[0] != 0 || p[1] != 0 || p[2] != 0).count();
                            // 输出之前捕获的诊断消息。
                            if let Some(diag) = state.pending_diag.take() {
                                let _ = tx.send(CapturerEvent::Log(diag));
                            }
                            let _ = tx.send(CapturerEvent::Log(format!(
                                "frame OK: {}x{} ({} bytes) pixel_sample={}/2000 non-zero",
                                frame.w, frame.h, frame.data.len(), nz,
                            )));
                        }
                        frame_count += 1;
                        skip_count = 0;
                        let _ = tx.send(CapturerEvent::Frame(
                            frame.w, frame.h, frame.data, frame.ts_ns,
                        ));
                        let logical_w = (state.pixel_w as f64 / state.scale) as i32;
                        let logical_h = (state.pixel_h as f64 / state.scale) as i32;
                        let vp_x = shared.vp_x.load(Ordering::Relaxed);
                        let vp_y = shared.vp_y.load(Ordering::Relaxed);
                        let _ = tx.send(CapturerEvent::Meta(
                            logical_w,
                            logical_h,
                            vp_x,
                            vp_y,
                            frame.applied_w,
                            frame.applied_h,
                            state.scale,
                        ));
                        // 周期性缩略图。
                        if state.last_thumb.elapsed() >= config::timing::THUMB_INTERVAL {
                            state.last_thumb = Instant::now();
                            if let Ok(Some(jpeg)) = generate_thumbnail(&state) {
                                let _ = tx.send(CapturerEvent::Thumbnail(jpeg));
                            }
                        }
                    }
                    Ok(None) => {
                        skip_count += 1;
                        if skip_count == 1 {
                            let icon = unsafe { IsIconic(state.hwnd) };
                            let vis = unsafe { IsWindowVisible(state.hwnd) };
                            let _ = tx.send(CapturerEvent::Log(format!(
                                "capture skip #1: icon={} vis={} hwnd={:?}",
                                icon.as_bool(),
                                vis.as_bool(),
                                state.hwnd.0,
                            )));
                        }
                    }
                    Err(e) => {
                        let _ = tx.send(CapturerEvent::Error(e));
                        break;
                    }
                }

                let elapsed = start.elapsed().as_millis() as u64;
                if elapsed < state.frame_interval_ms {
                    thread::sleep(std::time::Duration::from_millis(
                        state.frame_interval_ms - elapsed,
                    ));
                }
            }

            // 清理 GDI 资源。
            unsafe {
                SelectObject(state.mem_dc, HBITMAP::default());
                let _ = DeleteObject(state.mem_bmp);
                let _ = DeleteDC(state.mem_dc);
            }
        });
    }

    /// 更新视口（逻辑坐标）。通过原子变量即时同步到采集线程。
    pub fn set_viewport(&self, x: i32, y: i32, w: i32, h: i32) {
        self.shared.vp_x.store(x.max(0), Ordering::SeqCst);
        self.shared.vp_y.store(y.max(0), Ordering::SeqCst);
        self.shared.vp_w.store(w.max(1), Ordering::SeqCst);
        self.shared.vp_h.store(h.max(1), Ordering::SeqCst);
    }

    /// 停止采集（通知采集线程退出并清理资源）。
    pub fn stop(&self) {
        self.shared.running.store(false, Ordering::SeqCst);
    }
}

struct CapturedFrame {
    data: Vec<u8>,
    w: u32,
    h: u32,
    applied_w: i32,
    applied_h: i32,
    ts_ns: i64,
}

/// 采集一帧窗口画面，按共享视口裁剪子区域。
fn capture_frame(
    state: &mut CaptureState,
    shared: &CaptureShared,
) -> Result<Option<CapturedFrame>, String> {
    // 检查窗口是否最小化。
    if unsafe { IsIconic(state.hwnd) }.as_bool() {
        return Ok(None);
    }
    if !unsafe { IsWindowVisible(state.hwnd) }.as_bool() {
        return Ok(None);
    }

    let w = state.pixel_w;
    let h = state.pixel_h;
    let size = (w * h * 4) as usize;
    if state.full_rgba.len() != size {
        state.full_rgba.resize(size, 0);
    }

    // 步骤 1：尝试 WM_PRINT（适用于标准 Win32 控件窗口）。
    let wm_print_ok = unsafe {
        SendMessageW(
            state.hwnd,
            WM_PRINT,
            WPARAM(state.mem_dc.0 as usize),
            LPARAM((PRF_CLIENT | PRF_CHILDREN | PRF_ERASEBKGND) as isize),
        ).0 != 0
    };

    // 步骤 2：WM_PRINT 不支持 GPU 加速窗口，回退到屏幕 BitBlt。
    if !wm_print_ok {
        let screen_dc = unsafe { GetDC(HWND(std::ptr::null_mut())) };
        if screen_dc.is_invalid() {
            return Ok(None);
        }
        // 诊断：同时从屏幕 (0,0) 取 50x50 验证 BitBlt 管线。
        if !state.diag_done {
            state.diag_done = true;
            if let Some(nz) = diag_screen_zero(screen_dc) {
                let msg = format!("diag screen(0,0): {}/2500 non-zero pixels", nz);
                // 暂存在 state 里，在帧日志中输出。
                state.pending_diag = Some(msg);
            }
        }
        unsafe {
            let _ = BitBlt(
                state.mem_dc, 0, 0, w, h,
                screen_dc, state.win_left, state.win_top,
                SRCCOPY,
            );
            ReleaseDC(HWND(std::ptr::null_mut()), screen_dc);
        }
    }

    // 步骤 3：从内存 DC 提取 BGRA 像素。
    let mut bmi = BITMAPINFO {
        bmiHeader: BITMAPINFOHEADER {
            biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
            biWidth: w,
            biHeight: -h, // top-down
            biPlanes: 1,
            biBitCount: 32,
            biCompression: 0, // BI_RGB
            biSizeImage: 0,
            biXPelsPerMeter: 0,
            biYPelsPerMeter: 0,
            biClrUsed: 0,
            biClrImportant: 0,
        },
        bmiColors: [unsafe { std::mem::zeroed() }; 1],
    };
    let scan_lines = unsafe {
        GetDIBits(
            state.mem_dc, state.mem_bmp, 0, h as u32,
            Some(state.full_rgba.as_mut_ptr() as *mut _),
            &mut bmi, DIB_RGB_COLORS,
        )
    };
    if scan_lines == 0 {
        return Ok(None);
    }

    let scale = state.scale;

    // 从共享状态读取当前视口。
    let desired_vp_w = shared.vp_w.load(Ordering::Relaxed);
    let desired_vp_h = shared.vp_h.load(Ordering::Relaxed);
    let vp_x_raw = shared.vp_x.load(Ordering::Relaxed);
    let vp_y_raw = shared.vp_y.load(Ordering::Relaxed);

    // 裁剪视口子区域（物理像素系）。
    let phys_vp_w = ((desired_vp_w as f64 * scale) as i32).min(w);
    let phys_vp_h = ((desired_vp_h as f64 * scale) as i32).min(h);
    let phys_vp_x = ((vp_x_raw as f64 * scale) as i32).max(0).min(w - phys_vp_w);
    let phys_vp_y = ((vp_y_raw as f64 * scale) as i32).max(0).min(h - phys_vp_h);

    // 反推钳制后的逻辑视口，写回共享状态供下次 delta 拖动起点对齐。
    shared.vp_x.store((phys_vp_x as f64 / scale) as i32, Ordering::Relaxed);
    shared.vp_y.store((phys_vp_y as f64 / scale) as i32, Ordering::Relaxed);

    // 从全窗 BGRA 中提取视口子区域。
    let out_w = phys_vp_w as usize;
    let out_h = phys_vp_h as usize;
    let mut cropped = vec![0u8; out_w * out_h * 4];

    for row in 0..out_h {
        let src_row = phys_vp_y as usize + row;
        if src_row >= h as usize {
            break;
        }
        let src_start = (src_row * w as usize + phys_vp_x as usize) * 4;
        let dst_start = row * out_w * 4;
        let copy_len = (out_w * 4).min(state.full_rgba.len().saturating_sub(src_start));
        cropped[dst_start..dst_start + copy_len]
            .copy_from_slice(&state.full_rgba[src_start..src_start + copy_len]);
    }

    let ts_ns = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos() as i64)
        .unwrap_or(0);

    Ok(Some(CapturedFrame {
        data: cropped,
        w: out_w as u32,
        h: out_h as u32,
        applied_w: (phys_vp_w as f64 / scale) as i32,
        applied_h: (phys_vp_h as f64 / scale) as i32,
        ts_ns,
    }))
}

/// 生成整窗降采样缩略图 JPEG。
fn generate_thumbnail(state: &CaptureState) -> Result<Option<Vec<u8>>, String> {
    let w = state.pixel_w as u32;
    let h = state.pixel_h as u32;
    if w < 4 || h < 4 {
        return Ok(None);
    }

    let max_edge = config::timing::THUMB_MAX_EDGE;
    let scale = (1.0f64).min(max_edge as f64 / w.max(h) as f64);
    let thumb_w = (w as f64 * scale).round() as u32;
    let thumb_h = (h as f64 * scale).round() as u32;

    if thumb_w < 2 || thumb_h < 2 {
        return Ok(None);
    }

    // 简单最近邻降采样。
    let mut thumb = vec![0u8; (thumb_w * thumb_h * 4) as usize];
    for ty in 0..thumb_h {
        let sy = (ty as f64 / scale) as u32;
        for tx in 0..thumb_w {
            let sx = (tx as f64 / scale) as u32;
            let si = ((sy * w + sx) * 4) as usize;
            let ti = ((ty * thumb_w + tx) * 4) as usize;
            if si + 3 < state.full_rgba.len() {
                thumb[ti] = state.full_rgba[si]; // B
                thumb[ti + 1] = state.full_rgba[si + 1]; // G
                thumb[ti + 2] = state.full_rgba[si + 2]; // R
                thumb[ti + 3] = 255; // A
            }
        }
    }

    // BGRA → RGB 用于 JPEG 编码。
    let mut rgb = vec![0u8; (thumb_w * thumb_h * 3) as usize];
    for i in 0..(thumb_w * thumb_h) as usize {
        let bgra_i = i * 4;
        let rgb_i = i * 3;
        rgb[rgb_i] = thumb[bgra_i + 2];     // R
        rgb[rgb_i + 1] = thumb[bgra_i + 1]; // G
        rgb[rgb_i + 2] = thumb[bgra_i];     // B
    }

    // JPEG 编码。
    let mut jpeg_buf = std::io::Cursor::new(Vec::new());
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg_buf, 55);
    if encoder
        .encode(&rgb, thumb_w, thumb_h, image::ExtendedColorType::Rgb8)
        .is_err()
    {
        return Ok(None);
    }

    Ok(Some(jpeg_buf.into_inner()))
}

/// 按 app 名 + 窗口标题匹配窗口。
/// 优先标题完全匹配；否则取该应用最大的可见窗口。
fn find_window(app: &str, title: &str) -> Option<HWND> {
    struct SearchCtx {
        app: String,
        title: String,
        exact: Option<HWND>,
        /// (hwnd, area) — 最大窗口
        largest: Option<(HWND, i32)>,
    }

    unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let ctx = &mut *(lparam.0 as *mut SearchCtx);

        if !IsWindowVisible(hwnd).as_bool() {
            return true.into();
        }
        if IsIconic(hwnd).as_bool() {
            return true.into();
        }

        let mut pid: u32 = 0;
        GetWindowThreadProcessId(hwnd, Some(&mut pid));
        if pid == 0 {
            return true.into();
        }

        let proc_name = match process_exe_name(pid) {
            Some(n) => n,
            None => return true.into(),
        };
        if !proc_name.eq_ignore_ascii_case(&ctx.app) {
            return true.into();
        }

        let win_title = window_title(hwnd);

        // 跳过无标题窗口（桌面等）。
        if win_title.is_empty() {
            return true.into();
        }

        if win_title == ctx.title {
            ctx.exact = Some(hwnd);
            return false.into(); // 找到精确匹配，停止枚举。
        }

        // 计算窗口面积。
        let mut rect = RECT::default();
        if GetWindowRect(hwnd, &mut rect).is_ok() {
            let area = (rect.right - rect.left) * (rect.bottom - rect.top);
            if area > ctx.largest.as_ref().map_or(0, |(_, a)| *a) {
                ctx.largest = Some((hwnd, area));
            }
        }

        true.into()
    }

    let mut ctx = SearchCtx {
        app: app.to_string(),
        title: title.to_string(),
        exact: None,
        largest: None,
    };

    unsafe {
        let _ = EnumWindows(Some(enum_proc), LPARAM(&mut ctx as *mut _ as isize));
    }

    ctx.exact.or_else(|| ctx.largest.map(|(h, _)| h))
}

fn window_title(hwnd: HWND) -> String {
    unsafe {
        let len = GetWindowTextLengthW(hwnd);
        if len <= 0 {
            return String::new();
        }
        let mut buf = vec![0u16; (len + 1) as usize];
        let copied = GetWindowTextW(hwnd, &mut buf);
        if copied <= 0 {
            return String::new();
        }
        String::from_utf16_lossy(&buf[..copied as usize])
    }
}

/// 从屏幕 (0,0) 取 50x50 像素验证 DC + BitBlt 管线正常。
fn diag_screen_zero(screen_dc: HDC) -> Option<u32> {
    unsafe {
        let diag_bmp = CreateCompatibleBitmap(screen_dc, 50, 50);
        if diag_bmp.is_invalid() { return None; }
        let diag_dc = CreateCompatibleDC(screen_dc);
        let prev = SelectObject(diag_dc, diag_bmp);
        let _ = BitBlt(diag_dc, 0, 0, 50, 50, screen_dc, 0, 0, SRCCOPY);
        let mut buf = vec![0u8; 50 * 50 * 4];
        let mut bmi = BITMAPINFO {
            bmiHeader: BITMAPINFOHEADER {
                biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
                biWidth: 50, biHeight: -50, biPlanes: 1, biBitCount: 32,
                biCompression: 0, biSizeImage: 0,
                biXPelsPerMeter: 0, biYPelsPerMeter: 0,
                biClrUsed: 0, biClrImportant: 0,
            },
            bmiColors: [std::mem::zeroed(); 1],
        };
        GetDIBits(diag_dc, diag_bmp, 0, 50, Some(buf.as_mut_ptr() as *mut _), &mut bmi, DIB_RGB_COLORS);
        let nz = buf.chunks(4).filter(|p| p[0] != 0 || p[1] != 0 || p[2] != 0).count() as u32;
        SelectObject(diag_dc, prev);
        DeleteDC(diag_dc);
        DeleteObject(diag_bmp);
        Some(nz)
    }
}

fn process_exe_name(pid: u32) -> Option<String> {
    unsafe {
        let handle = OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE,
            false,
            pid,
        )
        .ok()?;
        let mut buf = vec![0u16; 260];
        let mut size = buf.len() as u32;
        let ok = QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_FORMAT(0),
            windows::core::PWSTR(buf.as_mut_ptr()),
            &mut size,
        );
        let _ = CloseHandle(handle);
        if ok.is_err() {
            return None;
        }
        let full = String::from_utf16_lossy(&buf[..size as usize]);
        let file = full.rsplit(['\\', '/']).next().unwrap_or(&full);
        let stem = file
            .strip_suffix(".exe")
            .or_else(|| file.strip_suffix(".EXE"))
            .unwrap_or(file);
        Some(stem.to_string())
    }
}
