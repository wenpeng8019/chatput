# Chatput（聊入）

用手机对着说话，文字实时注入到 Windows/Mac 桌面端「当前焦点输入框」。
手机端是类 IM 界面：每个桌面输入窗口 = 一个会话，按住说话、抬起发送。

## 架构

```
📱 Flutter App ──WebRTC DataChannel──► 💻 原生桌面端 (macOS/Windows)
   - IM 会话 UI                            - 焦点窗口监控
   - 系统语音识别(STT)                       - 文字注入(剪贴板+Cmd/Ctrl+V)
        │                                        │
        └────────── ☁️ 信令服务器(Node) ─────────┘
                    仅交换 SDP/ICE + 扫码配对
```

- **语音识别**：Android 端已改为 `sherpa-onnx` 本地离线识别，默认使用 SenseVoice 多语言模型；可选追加纯英文 `Paraformer English int8` 模型，用于双击语音键后进入英文输入。
- **连接**：WebRTC P2P DataChannel，端到端、低延迟；服务器只做信令与配对。
- **配对**：桌面显示二维码（roomId+token），手机扫码加入同一房间。

## 目录

| 目录 | 说明 | 运行依赖 |
|---|---|---|
| `signaling-server/` | WebRTC 信令服务器（房间+配对+转发） | Node ✅ 已装 |
| `desktop-macos/` | 原生 macOS 桌面端（Swift/SwiftUI + WebRTC + AXObserver，主力） | Xcode |
| `desktop-windows/` | 原生 Windows 桌面端（Rust） | Rust |
| `mobile-android/` | 原生 Android App（Kotlin + sherpa-onnx 离线语音识别） | Android SDK/JDK |
| `mobile-iphone/` | iOS 手机端（计划中，占位） | — |

> ⚠️ 大体积二进制（语音模型、WebRTC/sherpa-onnx 框架）未入库，见 `.gitignore`。

## 下载依赖（克隆后首次必做）

大体积二进制依赖通过脚本下载（详见脚本头部说明）：
```bash
./scripts/fetch-deps.sh            # 全部（Android 标准/英文模型 + macOS WebRTC）
./scripts/fetch-deps.sh android    # Android 标准版依赖（AAR + 默认模型）
./scripts/fetch-deps.sh android-english  # Android 英文版依赖（AAR + 默认模型 + 英文模型）
./scripts/fetch-deps.sh macos      # 仅 macOS
USE_MIRROR=1 ./scripts/fetch-deps.sh   # 中国大陆走 ghfast.top 代理加速
```
脚本幂等：已存在的文件自动跳过，`FORCE=1` 可强制重下。

当前 Android 语音模型约定：
- 默认模型：`sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17`
- 可选英文模型：`sherpa-onnx-paraformer-en-2024-03-09`
- 默认模型路径：`mobile-android/app/src/main/assets/<model-dir>/`
- 英文模型路径：`mobile-android/app/src/english/assets/<model-dir>/`
- 英文模型来源：sherpa-onnx 官方预训练模型项目 `csukuangfj/sherpa-onnx-paraformer-en-2024-03-09`

Android 现支持两个可选构建版本：
- `standard`：只打包默认 SenseVoice 模型，不提供英文双击输入
- `english`：额外打包 Paraformer 英文模型，开启英文双击输入

说明：`english` 构建会在编译期开启英文模型能力；若英文模型资源缺失，运行时仍会自动降级为默认模式。

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

### 3) 启动手机端（原生 Android）
```bash
export JAVA_HOME=/path/to/JDK
./scripts/build-android.sh                    # 标准版：构建并部署
./scripts/build-android.sh --variant english  # 英文版：构建并部署
./scripts/build-android.sh --open             # 部署后自动打开
./scripts/build-android.sh --no-deploy        # 只构建，不安装
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
