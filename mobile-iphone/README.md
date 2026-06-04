# mobile-iphone

iOS 原生手机端，按 Android 端当前产品形态实现：扫码配对、多桌面连接、会话列表、按住说话、文字输入、光标/回车/删除操作、历史连接重连。

## 功能对齐

- 扫码配对：使用 AVFoundation 扫桌面端二维码。
- 多桌面连接：一个 iPhone 客户端可同时连接多个桌面房间。
- 传输协议：复用桌面端/Android 端协议。
	- 信令：`join-room`、`signal`、`message`、`peer-left`、`error`
	- 业务消息：`session`、`session-closed`、`text`、`action`、`hello`
- 传输模式：支持二维码中的 `transport` 字段。
	- `webrtc`：iOS 作为 guest 接收 offer、创建 answer，通过 DataChannel 通信。
	- `websocket`：通过信令 WebSocket 转发业务消息。
- 主界面：与 Android 对齐的 header、状态 chip、历史连接、底部扫码按钮、会话列表。
- 聊天界面：会话 header、消息历史、按住说话、上滑呼出文字输入、回删/长按清空、换行/长按回车、更多菜单全选/清空。
- 语音识别：使用 iOS `SFSpeechRecognizer` + `AVAudioEngine`。双击语音按钮进入英文识别模式。

## 依赖

- Xcode
- XcodeGen
- `../desktop-macos/Frameworks/WebRTC.xcframework`，其中已包含 iOS 真机/模拟器 slice。

## 生成工程

```bash
cd mobile-iphone
export PATH="$HOME/.local/bin:$PATH"
xcodegen generate
```

生成后打开：

```bash
open ChatputPhone.xcodeproj
```

## 命令行验证

当前机器的 Xcode 可列出 iOS SDK，但 `xcodebuild` destination 报 iOS platform 未安装；在安装对应 iOS platform/runtime 后，可直接使用 Xcode 或：

```bash
xcodebuild -project ChatputPhone.xcodeproj -scheme ChatputPhone \
	-configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' build
```

查看当前是否已安装模拟器运行时：

```bash
xcrun simctl list runtimes
```

安装 Xcode 的 iOS Simulator runtime 后，可以用模拟器测试 UI、信令、WebRTC、扫码粘贴配对和文字输入；扫码页在无摄像头环境下会显示“粘贴二维码”，可直接粘贴桌面端二维码图片，或粘贴二维码里的 JSON 内容进行配对。

语音输入建议在真机验证。当前模拟器环境的 `AVAudioEngine`/`AURemoteIO` 在真实麦克风输入下可能直接触发系统级 abort，应用无法捕获；模拟器构建会自动禁用按住说话并切到文字输入，避免测试过程中崩溃。

在该环境下已通过源码级类型检查：

```bash
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
find Sources -name '*.swift' -print0 | xargs -0 xcrun swiftc -typecheck \
	-target arm64-apple-ios16.0 \
	-sdk "$sdk" \
	-F ../desktop-macos/Frameworks/WebRTC.xcframework/ios-arm64
```

## 权限

`Info.plist` 已配置：

- 摄像头：扫码配对
- 麦克风：语音输入
- 语音识别：语音转文字
- 局域网：访问桌面端信令服务
- ATS 任意加载：支持局域网 `ws://...` 调试
