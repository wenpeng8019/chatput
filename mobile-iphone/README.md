# mobile-iphone

iOS 手机端（计划中，尚未开发）。

## 目标
与 `mobile-android` 对等的 iOS 原生客户端：
- WebRTC GUEST（扫码加入房间、应答 offer）
- 离线语音识别（按住说话 → 文字）
- 扫码配对（AVFoundation 摄像头扫二维码）
- 按住说话交互界面

## 复用约定
信令与 DataChannel 协议同其他端，保持一致：
- 信令：`join-room` → `peer-joined` → `signal`
- DataChannel `input`：收 `{type:"session", ...}`，发 `{type:"text", text, sessionId}`

## 技术选型（待定）
- Swift / SwiftUI
- WebRTC：stasel/WebRTC（与 desktop-macos 同源，M125）
- 语音识别：sherpa-onnx iOS（SenseVoice 离线模型，与 Android 同模型）或 Apple Speech 框架

> 当前为占位目录，等核心链路打磨后启动开发。
