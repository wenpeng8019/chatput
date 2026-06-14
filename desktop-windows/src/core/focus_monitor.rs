//! 用 SetWinEventHook 监控焦点窗口变化（对标 macOS 的 AXObserver）。
//! 监听前台窗口切换 + 焦点对象变化，焦点变了就回调一个会话。
//! 另用轮询检测已上报窗口是否仍存在，关闭时回调移除。

use crate::core::config;
use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{SystemTime, UNIX_EPOCH};

use windows::Win32::Foundation::{BOOL, HWND, LPARAM, WPARAM};
use windows::Win32::UI::Accessibility::{SetWinEventHook, UnhookWinEvent, HWINEVENTHOOK};
use windows::Win32::UI::WindowsAndMessaging::{
    DispatchMessageW, EnumWindows, GetClassNameW, GetForegroundWindow, GetMessageW,
    GetWindowTextLengthW, GetWindowTextW, GetWindowThreadProcessId, IsWindowVisible,
    PostThreadMessageW, TranslateMessage, EVENT_OBJECT_FOCUS, EVENT_SYSTEM_FOREGROUND, MSG,
    WINEVENT_OUTOFCONTEXT, WINEVENT_SKIPOWNPROCESS, WM_QUIT,
};
use windows::Win32::System::Threading::GetCurrentProcessId;

const SESSION_CLOSE_MISS_THRESHOLD: u8 = 3;

/// 桌面端单一会话（= 一个被聚焦的输入窗口）。
#[derive(Clone, Debug, PartialEq)]
pub struct FocusSession {
    /// sessionId：Windows 侧使用稳定的窗口句柄，避免标题变化时被误判为新窗口。
    pub id: String,
    pub app: String,
    pub title: String,
    pub ts: f64,
}

/// 焦点监控事件，发送到协调器。
pub enum FocusEvent {
    Session(FocusSession),
    SessionClosed(String),
    /// 桌面窗口仍在但输入控件暂时不可用（如 AI 助手弹出菜单遮住了输入框）。
    SessionInputLost(String),
}

/// 焦点监控器：内部起一个带消息循环的线程跑 WinEventHook，
/// 另起一个轮询线程做窗口存活检测。事件经 channel 输出。
pub struct FocusMonitor {
    rx: Option<Receiver<FocusEvent>>,
    hook_thread_id: Arc<Mutex<u32>>,
    resend_flag: Arc<Mutex<bool>>,
    running: Arc<Mutex<bool>>,
    known: Arc<Mutex<HashMap<String, KnownSession>>>,
}

#[derive(Clone)]
struct KnownSession {
    missed_polls: u8,
}

// 线程内共享给 WinEvent 回调的状态（通过 thread_local，因回调是 extern "system" 无 self）。
thread_local! {
    static CB_STATE: std::cell::RefCell<Option<CallbackState>> = const { std::cell::RefCell::new(None) };
}

struct CallbackState {
    tx: Sender<FocusEvent>,
    last_key: String,
    own_pid: u32,
    known: Arc<Mutex<HashMap<String, KnownSession>>>,
    resend_flag: Arc<Mutex<bool>>,
}

impl FocusMonitor {
    pub fn new() -> Self {
        FocusMonitor {
            rx: None,
            hook_thread_id: Arc::new(Mutex::new(0)),
            resend_flag: Arc::new(Mutex::new(false)),
            running: Arc::new(Mutex::new(false)),
            known: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// 取出事件接收端（仅首次有效）。
    pub fn take_receiver(&mut self) -> Option<Receiver<FocusEvent>> {
        self.rx.take()
    }

    /// 启动监控（幂等）。
    pub fn start(&mut self) {
        {
            let mut running = self.running.lock().unwrap();
            if *running {
                self.resend_current();
                return;
            }
            *running = true;
        }

        let (tx, rx) = mpsc::channel::<FocusEvent>();
        self.rx = Some(rx);

        let hook_thread_id = self.hook_thread_id.clone();
        let resend_flag = self.resend_flag.clone();
        let known = self.known.clone();

        // WinEventHook 线程（需自带消息循环）。
        let tx_hook = tx.clone();
        let known_hook = known.clone();
        let resend_hook = resend_flag.clone();
        thread::spawn(move || {
            let own_pid = unsafe { GetCurrentProcessId() };
            CB_STATE.with(|s| {
                *s.borrow_mut() = Some(CallbackState {
                    tx: tx_hook,
                    last_key: String::new(),
                    own_pid,
                    known: known_hook,
                    resend_flag: resend_hook,
                });
            });

            // 记录本线程 ID，便于停止时 PostThreadMessage(WM_QUIT)。
            unsafe {
                let tid = windows::Win32::System::Threading::GetCurrentThreadId();
                *hook_thread_id.lock().unwrap() = tid;
            }

            let hook_fg = unsafe {
                SetWinEventHook(
                    EVENT_SYSTEM_FOREGROUND,
                    EVENT_SYSTEM_FOREGROUND,
                    None,
                    Some(win_event_proc),
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
                )
            };
            let hook_focus = unsafe {
                SetWinEventHook(
                    EVENT_OBJECT_FOCUS,
                    EVENT_OBJECT_FOCUS,
                    None,
                    Some(win_event_proc),
                    0,
                    0,
                    WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS,
                )
            };

            // 启动即发一次当前焦点。
            emit_current();

            // 标准消息循环。
            unsafe {
                let mut msg = MSG::default();
                while GetMessageW(&mut msg, HWND::default(), 0, 0).as_bool() {
                    // 补发请求：线程消息（hwnd 为空）不会被派发到窗口过程，需在此显式处理。
                    if msg.message == WM_APP_RESEND {
                        emit_current();
                        continue;
                    }
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                }
                if !hook_fg.is_invalid() {
                    let _ = UnhookWinEvent(hook_fg);
                }
                if !hook_focus.is_invalid() {
                    let _ = UnhookWinEvent(hook_focus);
                }
            }
        });

        // 窗口存活轮询线程。
        let tx_poll = tx;
        let known_poll = known;
        let running_poll = self.running.clone();
        thread::spawn(move || {
            loop {
                thread::sleep(config::timing::WINDOW_EXISTENCE_POLL);
                if !*running_poll.lock().unwrap() {
                    break;
                }
                remove_closed_sessions(&known_poll, &tx_poll);
            }
        });
    }

    /// 强制重新发出当前焦点会话（忽略去重）。用于 DataChannel 刚建立时补发。
    pub fn resend_current(&self) {
        *self.resend_flag.lock().unwrap() = true;
        // 唤醒 hook 线程做一次 emit：投递一个自定义消息（WM_APP）。
        let tid = *self.hook_thread_id.lock().unwrap();
        if tid != 0 {
            unsafe {
                let _ = PostThreadMessageW(tid, WM_APP_RESEND, WPARAM(0), LPARAM(0));
            }
        }
    }

    /// 已在监控时补发当前焦点；未启动时先启动。
    pub fn ensure_current_delivered(&mut self) {
        if *self.running.lock().unwrap() {
            self.resend_current();
        } else {
            self.start();
        }
    }
}

const WM_APP_RESEND: u32 = 0x8000 + 1; // WM_APP + 1

/// WinEvent 回调：焦点/前台变化时触发，读取当前焦点并发出会话。
unsafe extern "system" fn win_event_proc(
    _hook: HWINEVENTHOOK,
    _event: u32,
    _hwnd: HWND,
    _id_object: i32,
    _id_child: i32,
    _thread: u32,
    _time: u32,
) {
    emit_current();
}

/// 读取当前前台窗口，构造会话并（去重后）发出。
fn emit_current() {
    CB_STATE.with(|s| {
        let mut guard = s.borrow_mut();
        let st = match guard.as_mut() {
            Some(st) => st,
            None => return,
        };

        let hwnd = unsafe { GetForegroundWindow() };
        if hwnd.0.is_null() {
            return;
        }

        // 跳过自身进程窗口。
        let mut pid: u32 = 0;
        unsafe {
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
        }
        if pid == st.own_pid || pid == 0 {
            return;
        }

        // 点击系统桌面时前台窗口变为桌面外壳（Progman/WorkerW），不是可输入目标。
        if is_desktop_shell(hwnd) {
            return;
        }

        let title = window_title(hwnd);
        let app = process_name(pid).unwrap_or_else(|| "Unknown".to_string());
        if title.is_empty() {
            // 桌面/无标题窗口不是可输入目标。
            return;
        }

        let session_id = session_id(hwnd);
        let key = format!("{}|{}|{}", session_id, app, title);

        // 处理补发请求：重置去重键。
        let force = {
            let mut rf = st.resend_flag.lock().unwrap();
            let v = *rf;
            *rf = false;
            v
        };
        if force {
            st.last_key.clear();
        }
        if key == st.last_key {
            return;
        }
        st.last_key = key.clone();

        let ts = now_millis();
        let session = FocusSession {
            id: session_id.clone(),
            app: app.clone(),
            title,
            ts,
        };
        st.known.lock().unwrap().insert(
            session_id,
            KnownSession {
                missed_polls: 0,
            },
        );
        let _ = st.tx.send(FocusEvent::Session(session));
    });
}

/// 轮询：移除已不存在的已上报窗口会话。
fn remove_closed_sessions(
    known: &Arc<Mutex<HashMap<String, KnownSession>>>,
    tx: &Sender<FocusEvent>,
) {
    let snapshot: Vec<String> = {
        let g = known.lock().unwrap();
        if g.is_empty() {
            return;
        }
        g.keys().cloned().collect()
    };

    // 枚举所有可见窗口，构造存活会话集合。
    let live = enumerate_live_sessions();

    let mut closed: Vec<String> = Vec::new();
    {
        let mut g = known.lock().unwrap();
        for session_id in snapshot {
            if let Some(entry) = g.get_mut(&session_id) {
                if live.contains(&session_id) {
                    entry.missed_polls = 0;
                } else {
                    entry.missed_polls = entry.missed_polls.saturating_add(1);
                    if entry.missed_polls >= SESSION_CLOSE_MISS_THRESHOLD {
                        closed.push(session_id);
                    }
                }
            }
        }
        for id in &closed {
            g.remove(id);
        }
    }

    if !closed.is_empty() {
        for id in closed {
            let _ = tx.send(FocusEvent::SessionClosed(id));
        }
    }
}

fn enumerate_live_sessions() -> std::collections::HashSet<String> {
    use std::collections::HashSet;
    let mut set: Box<HashSet<String>> = Box::default();
    let ptr = &mut *set as *mut HashSet<String> as isize;
    unsafe {
        let _ = EnumWindows(Some(enum_proc), LPARAM(ptr));
    }
    *set
}

unsafe extern "system" fn enum_proc(hwnd: HWND, lparam: LPARAM) -> BOOL {
    use std::collections::HashSet;
    if !IsWindowVisible(hwnd).as_bool() {
        return true.into();
    }
    let mut pid: u32 = 0;
    GetWindowThreadProcessId(hwnd, Some(&mut pid));
    let own = GetCurrentProcessId();
    if pid == 0 || pid == own {
        return true.into();
    }
    if is_desktop_shell(hwnd) {
        return true.into();
    }
    let title = window_title(hwnd);
    if title.is_empty() {
        return true.into();
    }
    let set = &mut *(lparam.0 as *mut HashSet<String>);
    set.insert(session_id(hwnd));
    true.into()
}

/// 是否为系统桌面外壳窗口（点击桌面时的前台窗口）。
fn is_desktop_shell(hwnd: HWND) -> bool {
    let class = window_class(hwnd);
    class == "Progman" || class == "WorkerW"
}

fn window_class(hwnd: HWND) -> String {
    unsafe {
        let mut buf = [0u16; 256];
        let len = GetClassNameW(hwnd, &mut buf);
        if len <= 0 {
            return String::new();
        }
        String::from_utf16_lossy(&buf[..len as usize])
    }
}

fn session_id(hwnd: HWND) -> String {
    format!("win:{:x}", hwnd.0 as usize)
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

/// 由 PID 取进程可执行名（不含扩展名）作为 app 名。
fn process_name(pid: u32) -> Option<String> {
    use windows::Win32::Foundation::CloseHandle;
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_FORMAT, PROCESS_QUERY_LIMITED_INFORMATION,
    };
    unsafe {
        let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
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
        let stem = file.strip_suffix(".exe").or_else(|| file.strip_suffix(".EXE")).unwrap_or(file);
        Some(stem.to_string())
    }
}

fn now_millis() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

impl Drop for FocusMonitor {
    fn drop(&mut self) {
        *self.running.lock().unwrap() = false;
        let tid = *self.hook_thread_id.lock().unwrap();
        if tid != 0 {
            unsafe {
                let _ = PostThreadMessageW(tid, WM_QUIT, WPARAM(0), LPARAM(0));
            }
        }
    }
}
