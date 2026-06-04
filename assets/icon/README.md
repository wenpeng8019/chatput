# ChatPUT 应用图标

项目应用图标的源文件与生成脚本。

## 设计

VSCode 风格的素雅工具感蓝色 squircle 背景，白色图形 + 蓝色细节。两端用同一套元素、互为前后关系：

| 端 | 前景 | 背景 |
|----|------|------|
| **桌面端（macOS）** | 键盘（白底蓝键） | 聊天气泡（半透明剪影） |
| **手机端（Android）** | 聊天气泡（含语音波形） | 键盘（半透明剪影） |

寓意：手机「说话」→ 桌面「打字输入」。

## 目录

```
assets/icon/
├── src/
│   ├── chatput-desktop.svg            # 桌面端母版（1024×1024）
│   ├── chatput-mobile.svg             # 手机端母版（1024×1024）
│   └── chatput-mobile-foreground.svg  # Android 自适应图标前景层
├── generate.sh                        # 生成脚本
└── build/                             # 生成产物（git 可忽略）
```

## 生成

需要一个 SVG 渲染器（任选其一）：

```bash
brew install librsvg          # rsvg-convert（推荐）
# 或 brew install --cask inkscape
# 或 pipx install cairosvg
```

然后：

```bash
cd assets/icon
./generate.sh
```

产物：

- `build/macos/AppIcon.appiconset/`（含 `Contents.json`）与 `build/macos/ChatputDesktop.icns`
- `build/android/mipmap-*/`、`build/android/mipmap-anydpi-v26/`、`build/android/values/ic_launcher_background.xml`

## 接入

**macOS**：把 `build/macos/AppIcon.appiconset` 放进 Xcode 资源目录，或在 `project.yml` 中引用生成的 `.icns`。

**Android**：把 `build/android/` 下的 `mipmap-*`、`mipmap-anydpi-v26`、`values/ic_launcher_background.xml` 拷入 `mobile-android/app/src/main/res/`，并确认 `AndroidManifest.xml` 的 `android:icon="@mipmap/ic_launcher"`、`android:roundIcon="@mipmap/ic_launcher_round"`。
