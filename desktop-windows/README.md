# desktop-windows

Chatput 的 Windows 桌面端 —— 与 `desktop-macos` 功能对等的**纯原生单 exe**，
使用 **Rust + webrtc-rs**，无托管运行时（不依赖 .NET）。

## 功能
- **WebRTC HOST**（webrtc-rs）：创建房间、DataChannel `input`、发送 offer、收 answer/candidate
- **内置信令服务器**（tokio + tokio-tungstenite）：局域网零依赖，协议同 `signaling-server/`
- **信令客户端**：内置或外部信令，自动重连
- **焦点窗口检测**：Win32 `SetWinEventHook`（前台 + 焦点对象），对标 macOS 的 AXObserver
- **文字注入**：剪贴板 + `Ctrl+V`（`SendInput`），随后还原剪贴板；操作指令直接模拟按键
- **配对二维码 + 状态界面**：eframe/egui，系统托盘（tray-icon）常驻
- **传输模式**：WebRTC P2P / WebSocket 中继，可切换
- **开机自启**：写入 HKCU Run 注册表项
- **中英文本地化**：跟随系统或手动指定

## 线缆协议（跨平台一致）
- 信令：`create-room` → `room-created{roomId,token}`；`join-room{roomId,token}` → `peer-joined{role}`；`signal{data}`；`message{data}`；`peer-left`；`error{reason}`
- DataChannel 标签：`input`
- 桌面→手机：`session{sessionId,app,title,device,ts}`、`session-closed{sessionId}`
- 手机→桌面：`text{text}`、`action{action}`、`hello{device}`
- 二维码载荷：`{url, roomId, token, transport}`，`transport ∈ {webrtc, websocket}`

## 技术栈
- 异步运行时：`tokio`
- WebRTC：`webrtc` 0.11（webrtc-rs）
- WebSocket：`tokio-tungstenite`
- GUI / 托盘：`eframe`/`egui` + `tray-icon`
- 二维码：`qrcode`
- 平台 API：`windows` crate（SetWinEventHook、SendInput、剪贴板、GetAdaptersAddresses 等）
- 注册表：`winreg`

## 源码结构
```
src/
  main.rs                 入口（windows_subsystem，启动协调器 + egui）
  core/
    wire.rs               协议常量
    config.rs             时长/容量常量
    localization.rs       界面语言 + t()
    network_info.rs       局域网 IPv4 探测
    text_injector.rs      剪贴板粘贴 + 按键模拟
    focus_monitor.rs      SetWinEventHook 焦点监控
    login_item.rs         开机自启（注册表）
    qrcode_gen.rs         二维码 RGBA 生成
    signaling_client.rs   信令 WS 客户端
    signaling_server.rs   内置信令 WS 服务器
    webrtc_manager.rs     WebRTC HOST
  app/
    app_state.rs          共享状态
    settings.rs           配置持久化（%APPDATA%\Chatput\settings.json）
    coordinator.rs        顶层编排（tokio）
    ui.rs                 egui 界面 + 托盘
```

## 构建
需要 Rust（MSVC 工具链）与 VS Build Tools（C++ 生成工具）。

```powershell
cd desktop-windows
cargo build            # 调试
cargo build --release  # 发布（单 exe）
```

产物：`target/<profile>/chatput.exe`。

启动时默认使用 `Glow` 渲染后端，以避免部分远程桌面 / 受限图形环境下 `wgpu` 初始化崩溃。
如需强制切回 `wgpu`，可先设置环境变量：

```powershell
$env:CHATPUT_RENDERER = 'wgpu'
target\debug\chatput.exe
```

## 测试
内置信令服务器端到端校验：
```powershell
# 先运行 chatput.exe（会在 8080 监听），再执行：
powershell -ExecutionPolicy Bypass -File scripts\test-signaling.ps1
```
