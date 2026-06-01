# Chatput（聊入）

用手机对着说话，文字实时注入到 Windows/Mac 桌面端「当前焦点输入框」。
手机端是类 IM 界面：每个桌面输入窗口 = 一个会话，按住说话、抬起发送。

## 架构

```
📱 Flutter App ──WebRTC DataChannel──► 💻 Electron 桌面端
   - IM 会话 UI                            - 焦点窗口监控
   - 系统语音识别(STT)                       - 文字注入(剪贴板+Cmd/Ctrl+V)
        │                                        │
        └────────── ☁️ 信令服务器(Node) ─────────┘
                    仅交换 SDP/ICE + 扫码配对
```

- **语音识别**：复用手机系统 STT（iOS Speech / Android SpeechRecognizer），零服务器成本。
- **连接**：WebRTC P2P DataChannel，端到端、低延迟；服务器只做信令与配对。
- **配对**：桌面显示二维码（roomId+token），手机扫码加入同一房间。

## 目录

| 目录 | 说明 | 运行依赖 |
|---|---|---|
| `signaling-server/` | WebRTC 信令服务器（房间+配对+转发） | Node ✅ 已装 |
| `desktop-macos/` | 原生 macOS 桌面端（Swift/SwiftUI + WebRTC + AXObserver，主力） | Xcode |
| `desktop-electron/` | 早期 Electron 桌面端（已被 `desktop-macos` 取代，保留备查） | Node ✅ 已装 |
| `desktop-windows/` | Windows 桌面端（计划中，占位） | — |
| `mobile-android/` | 原生 Android App（Kotlin + sherpa-onnx 离线语音识别） | Android SDK/JDK |
| `mobile-iphone/` | iOS 手机端（计划中，占位） | — |

> ⚠️ 大体积二进制（语音模型、WebRTC/sherpa-onnx 框架）未入库，见 `.gitignore`。

## 下载依赖（克隆后首次必做）

大体积二进制依赖通过脚本下载（详见脚本头部说明）：
```bash
./scripts/fetch-deps.sh            # 全部（Android AAR+模型 + macOS WebRTC）
./scripts/fetch-deps.sh android    # 仅 Android
./scripts/fetch-deps.sh macos      # 仅 macOS
USE_MIRROR=1 ./scripts/fetch-deps.sh   # 中国大陆走 ghfast.top 代理加速
```
脚本幂等：已存在的文件自动跳过，`FORCE=1` 可强制重下。

## 快速开始（Phase 0：打通最小链路）

### 1) 启动信令服务器
```bash
cd signaling-server
npm install
npm start          # 默认 ws://localhost:8080
```

### 2) 启动桌面端（原生 macOS，主力）
```bash
cd desktop-macos
export PATH="$HOME/.local/bin:$PATH"
xcodegen generate   # 生成 Xcode 工程（首次或增删文件后）
xcodebuild -project ChatputDesktop.xcodeproj -scheme ChatputDesktop \
  -configuration Debug -derivedDataPath build \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
open build/Build/Products/Debug/ChatputDesktop.app   # 弹出窗口，显示配对二维码
```
> 首次需在「系统设置 → 隐私与安全性 → 辅助功能」中勾选 ChatputDesktop（焦点监控 + 文字注入都依赖）。
>
> 旧 Electron 版仍可用：`cd desktop-electron && npm install && npm start`。

### 3) 启动手机端（原生 Android）
```bash
cd mobile-android
export JAVA_HOME=/path/to/JDK
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## 路线图
- [x] Phase 0：三端最小链路打通（语音→P2P→注入）
- [ ] Phase 1：IM 界面产品化 + 焦点变化自动建会话
- [ ] Phase 2：体验打磨 + Windows 支持
- [ ] Phase 3：Tauri 重写桌面端（体积优化）/ 自建 whisper（可选）

## 配置
所有端的信令地址默认 `ws://localhost:8080`。
局域网真机联调时，改为电脑局域网 IP（如 `ws://192.168.1.10:8080`）。
详见各子目录 README 与 `config`。
