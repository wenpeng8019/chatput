# desktop-windows

Windows 桌面端（计划中，尚未开发）。

## 目标
与 `desktop-macos` 对等的 Windows 原生客户端：
- WebRTC HOST（创建房间、DataChannel `input`、发送 offer）
- 焦点窗口检测（Win32 `SetWinEventHook` / UI Automation，对标 macOS 的 AXObserver）
- 文字注入（`SendInput` 模拟键盘，或剪贴板 + Ctrl+V）
- 配对二维码 + 状态界面

## 复用约定
信令与 DataChannel 协议同其他端，保持一致：
- 信令：`create-room` / `peer-joined(role)` / `signal` / `peer-left`
- DataChannel `input`：桌面→手机 `{type:"session", ...}`，手机→桌面 `{type:"text", text, sessionId}`

## 技术选型（待定）
- C# / WinUI 3 或 C++ / Win32
- WebRTC：Microsoft.MixedReality.WebRTC 或自带 libwebrtc

> 当前为占位目录，等 macOS 版稳定后启动开发。
