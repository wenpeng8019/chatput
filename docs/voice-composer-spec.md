# 语音操作面板 — UE 交互规格说明

本文件描述会话页底部「语音操作面板」（voice composer）的视觉结构、手势交互、阈值参数与触感反馈规格，作为 iOS / Android 双端对齐的依据。

- iOS 实现：`mobile-iphone/Sources/App/ChatView.swift`
- Android 实现：`mobile-android/app/src/main/java/com/chatput/app/ChatActivity.kt`、`DirectionHintsView.kt`、`res/layout/activity_chat.xml`

---

## 1. 视觉结构

```
            ┌─────────────────────────────────────────┐  ← 顶部圆角弧线装饰（左右各一）
            │  ⌫            🎤            ⏎            │
            │ 退格/清空    语音/光标     回车/Enter     │
            └─────────────────────────────────────────┘
              面板圆角 34，浅色 surface，1px 描边
```

- **面板**：圆角 `34`，背景 `surface`，描边 `line`，水平内边距 `20`、垂直内边距 `13`。
- **顶部圆角弧线装饰（CornerArc）**：面板左上 / 右上各一条同心弧线，半径等于面板 `cornerRadius = 34`，曲率与面板边缘完全一致；描边色 `textTertiary @ 0.28`，线宽 `1.8`，尺寸 `34×34`，右侧镜像。仅装饰，不参与命中测试。**此为 iOS 方案，圆角曲率与角落装饰存在平台差异，详见 §8。**
- **提示文字（hint）**：位于面板上方，默认「按住说话」；随面板一起上移淡出。
- 面板无可见「把手横线」——与 Android 一致（Android 的 `drag_handle` 是不可见的全宽感应层）。

---

## 2. 三个按钮

| 位置 | 按钮 | 轻点（tap） | 长按（hold 0.75s） |
|---|---|---|---|
| 左 | 退格 `delete.left` | `backspace` | `clear`（清空，toast「已清空」） |
| 中 | 语音 `mic.fill` | 见 §3 | 见 §3 |
| 右 | 回车 `return` | `shiftEnter` | `enter` |

### 按钮与图标尺寸（标准）

| 元素 | 容器 | 图标 | 说明 |
|---|---|---|---|
| 左右按钮（退格 / 回车） | `56` | iOS `font(size: 22)` / Android `27dp` | iOS 用 SF Symbol（字号），Android 用矢量图（dp） |
| 中间麦克风 | `78` | iOS `font(size: 30)` / Android `34dp` | 同上 |

> 两端容器尺寸一致（56 / 78）。图标的「标称数值」不同是有意为之：SF Symbol 在同一字号下渲染的字形比同等 dp 的矢量图更饱满，而 Android 矢量图的 `24×24` viewport 自带留白，因此 Android 需用更大的 dp 值才能让**可见字形**与 iOS 对齐。

### 长按进度按钮（HoldProgressButton）
- 按下即开始 `0.75s` 进度环动画（`holdDuration = 0.75`）。
- 满 `0.75s` 触发 `onHold`，伴随成功触感（`UINotificationFeedbackGenerator.success`）。
- 未满时松手触发 `onTap`，伴随轻触感（`.light`）。
- 手指滑出按钮范围（位移 > `size × 0.7`）视为取消，既不触发 tap 也不触发 hold。
- 按下时按钮缩放至 `0.94`。

---

## 3. 中间语音按钮手势

中间按钮承载「按住说话 + 拖动控光标 + 上下切行 + 双击英文」多合一手势，基于单个 `DragGesture(minimumDistance: 0)`。

### 3.1 按住说话
- 按下立即开始录音（`startTalking`），轻触感（`.light`），hint 变「正在听…」/「请说英文」。
- 松手：
  - 按压时长 `< 0.18s`（`tapMaxDuration`）→ 视为轻点，取消录音，进入「双击」判定。
  - 否则 → 停止录音并提交识别结果。

### 3.2 双击进入英文模式
- 轻点后 `0.35s`（`doubleTapMax`）内再次轻点，且英文识别可用 → 切换英文模式，hint「请说英文」。
- 单次轻点 → toast「再按一次进入英文输入」。

### 3.3 拖动进入光标模式（防误触保护区）
- **激活阈值**：手指位移 `hypot(dx, dy) > 28`（`cursorActivation = 28`）才切到光标模式。
  - 与 Android 对齐：Android 为 `max(scaledTouchSlop × 2, 28dp)`，典型即 `28dp`。
  - 此死区用于避免「按住说话」期间的小幅抖动误触发拖拽。
- **锁轴**：进入时按主方向锁定轴；垂直需明显占优（`|dy| > |dx| × 1.8`，`verticalBias`）才锁为「上下行」，否则默认「左右移光标」。
- 进入光标模式时丢弃录音，刚性触感（`.rigid`），麦克风保持蓝色（不变灰），hint 切换为方向提示，四周方向提示装饰按所锁轴向聚焦（见 §3.7）。

### 3.4 水平：棘轮式移动光标

水平拖动分两段，**滑动距离 ↔ 触发光标移动**的关系如下：

#### 阶段 A — 棘轮逐字（精确 1:1）
- **棘轮步长** `cursorStep = 24`：拖动距离每**累计 24**，发送一次 `cursorLeft` / `cursorRight`；反向跨过步长才回退一字。每步轻触感（`.light`）。
- 实现：`stepIndex = round(delta / 24)`，`stepIndex` 每变化 1 即移动一字（一次拖动跨多步会补发多次）。
- **基线**：`delta` 以**进入光标模式的位置**为起点（重定基线），保证进入瞬间不跳字、逐字精确可控。

#### 阶段 B — 连续自动移动（到侧按钮位置后）
- **触发点（到侧按钮中心）**：当手指从麦克风中心水平滑到**侧按钮（退格 / 回车）的中心位置**时，由「棘轮逐字」切为「连续自动移动」。
  - **这是两端对齐的统一标准**：阈值 = 麦克风中心 → 侧按钮中心的水平距离 = `面板内容宽 / 2 − 侧按钮半径(28)`。
  - **判定基准是「相对麦克风中心的绝对偏移」**，与阶段 A 的重定基线**解耦**——否则触发点会多偏移一个激活距离（约半个按钮）导致左右不对称：
    - iOS：`cursorAbsDelta = value.location.x − 55`（手势帧 110×110，中心 x=55），即手指距麦克风中心的水平偏移。
    - Android：`cursorContinuousDelta() = cursorAbsX − cursorOriginX`，`cursorOriginX` 为按下时 `btn_talk` 屏幕中心。
  - 阈值**随设备宽度自适应**，运行时动态计算，不是固定磁数：
    - iOS：`GeometryReader` 测面板内容宽，`cursorContinuousThreshold = 内容宽/2 − 28`。
    - Android：`cursorContinuousPx()` 取 `btn_talk` 与 `btn_backspace` 两视图中心的实际水平距离。
  - 回退默认值 `96`（布局尚未就绪时使用）。两端面板几何一致（屏幕边距 `18` + 面板内边距 `20`，侧按钮 `56`），故同一设备上两端阈值相等。
- **连续速度（越界越深越快）**：过阈后按时间自动重复，间隔随**绝对偏移**从 `repeatSlow = 0.2s`（5 次/秒）线性加速到 `repeatFast = 0.04s`（25 次/秒），在 `阈值 → 阈值 + 24×8(=192)` 区间内插值；越过该区间后维持最快。

> 小结：**阶段 A 是「距离换字数」（每 24 一字，精确）；阶段 B 是「位置换频率」（手指停在越界处，按时间持续移动，越深越快）。**

### 3.5 垂直：上下切行（swipe，非滑动）

与水平的「滑动 = 连续移动」不同，垂直是**一次 swipe 只切一行**——快速上/下划一下，松手切一行；不会随手指移动多少而连切多行。

#### 锁轴（进入时一次性判定）
- 在「按住说话」拖出激活距离 `cursorActivation = 28` 的瞬间，按主方向锁定轴：
  - 仅当**垂直明显占优** `|dy| > |dx| × verticalBias(1.8)` 才锁为「上下切行」；否则默认「左右移光标」。
- 锁定后该次手势不再切换轴向，避免斜向拖动反复抖动。

#### 触发关系（位移阈值，松手判定）
- 拖动**过程中只预判方向、不切行**，hint 随偏移提示「↑ 上滑松手切行 ↓」/「松手切到上一行/下一行」。
- **松手瞬间**判定：锁定轴上的偏移 `|delta| ≥ swipeTrigger = 32` → 发送**一次** `cursorUp`（上划）/ `cursorDown`（下划）；不足 `32` → 不切行、回到说话/空闲。
  - 一次完整 swipe 最多切 **1 行**，与水平阶段 A 的「每 24 一字、可连续多字」**不同**。要再切一行需重新做一次 swipe。
  - 方向：`delta > 0`（手指向下）→ `cursorDown`；`delta < 0`（手指向上）→ `cursorUp`。
- **两端统一标准**：`swipeTrigger = 32`、`verticalBias = 1.8` 双端一致（iOS pt / Android dp）。

#### 触感
- 切行成功：iOS `.medium` + 延迟 `0.06s` 再 `.light`（双段，区别于水平单击）；Android `KEYBOARD_TAP` 立即 + 延迟 `55ms` 再一次（`cursorStepHaptic` 中 `cursorVertical` 分支）。

> 小结：**垂直是「一次 swipe 一行」的离散触发（阈值 32，松手生效）；水平阶段 A 是「每 24 距离一字」的连续触发。二者刻意不同。**

### 3.6 按钮动效（UE）

#### 中间语音球（mic）
| 动效 | iOS | Android | 标准 |
|---|---|---|---|
| 按下缩放 | `scaleEffect 0.94`（录音中），`.easeOut 0.15s` | `scaleX/Y 0.93`，`130ms` | 按下/录音时球缩小到 **≈0.93**，约 `130–150ms` 缓出 |
| 光晕（halo） | `110×110` 圆环：`isTalking` 时 `scale 0.7→1.0`、`opacity 0→1`，`.easeOut 0.15s` | `orb_halo`：`active` 时 `alpha 0→1`、`scale 0.85→1.12`，`180ms` | 录音时外圈光晕**放大浮现**，停止时缩回淡出 |
| 进入光标模式 | 球底色保持 `accent`（不变灰），光晕收起 | 同（`setOrbActive(false)` 收起光晕） | 进入光标模式麦克风**保持蓝色**、光晕收起，方向由四周提示装饰表达（见 §3.7） |
| 阴影 | `accent` 阴影，录音时 `0.18→0.28`，半径 14 | —（无投影，Material 扁平） | 平台差异：iOS 有柔和投影，Android 扁平 |

#### 左右长按按钮（退格 / 回车）的进度环
- **核心标准（本次对齐）**：长按时的**旋转进度环半径与中间大按钮一致（直径 78）**，而非按钮自身（56）——环**溢出**按钮本体居中绘制。
  - iOS：`HoldProgressButton` 进度环移到 `.overlay`，独立 `ringSize = 78` 帧，按钮本体仍 `56`。
  - Android：`clear_progress` / `enter_progress` 的 `ProgressBar` 尺寸用 `control_primary(78dp)`，叠在 `56dp` 按钮上居中。
- **环线宽**：`ringSize / 20 ≈ 3.9`，对齐 Android `progress_ring_clear` 的 `thicknessRatio = 20`。
- **起始角 / 方向**：从正上方（12 点钟，`-90°` / `270°`）顺时针填充。
- **进度时长**：按下即开始填充，满 `holdDuration = 0.75s`（清空 / 回车长按）触发 `onHold`。
- **按下缩放**：按钮 `scaleEffect 0.94`（iOS），`.easeOut 0.1s`。
- **触感**：满环触发成功反馈（iOS `Notification.success` / Android `LONG_PRESS`）；未满松手为轻点（iOS `.light`）。

### 3.7 方向提示装饰（directionHints）

麦克风按钮四周的一组淡蓝装饰，**仅视觉、不参与命中测试**，用来暗示「这个按钮可以四向拖动」，并在连续触发时给出状态反馈。

- iOS：`directionHints`（`ChatView.swift`，ZStack 叠在 `talkButton` 上）。
- Android：`DirectionHintsView`（自定义 `View`，叠在 `btn_talk` 上，`activity_chat.xml`）。

#### 构成
- **四向扁角箭头（chevron）**：上下左右各一，使用扁平的「compact」造型（展宽大、进深小），暗示可拖动方向。
- **左右圆点**：左右两侧内侧各有圆点，暗示水平方向「可连续滑动」。

#### 布局规则
- **上下**：与麦克风中心距离固定（`vR = 49`），不随状态移动。
- **左右**：因左右留白多，chevron **不与上下对齐**，而是**紧挨最外侧的点**：
  - 常驻点位 `dotNear = 44`；连续态第二点位 `dotFar = 51`。
  - chevron 与最外侧点间距 `chevronGap = 9`，即 `hR = (连续态 ? dotFar : dotNear) + 9`。

#### 状态联动
| 状态 | 上下箭头 | 左右箭头 + 圆点 | 备注 |
|---|---|---|---|
| 空闲 | 显示 | 显示（单点） | 全显，暗示四向可拖 |
| 水平移光标 | **隐藏** | 显示 | 聚焦水平轴 |
| 连续触发（水平） | 隐藏 | **第二点淡入 + chevron 外移一格** | 单点裂变为双点 = 轨迹感，确认「已进入连续滑动」 |
| 垂直切行 | 显示 | **隐藏**（含圆点） | 聚焦垂直轴 |
| 录音中 | 整体淡出 | 整体淡出 | 说话时不干扰 |

- **设计原则**：沿哪个轴操作，就只保留哪个轴的提示（方向聚焦）。连续触发是**唯一**的动态变化——左右各淡入第二个点、chevron 随之外移让位，形成「轨道延伸」的连续感。

#### 视觉规格（两端对齐，pt≈dp）
| 项 | iOS | Android |
|---|---|---|
| 色彩 | `accent @ opacity 0.34` | `chatput_accent`，`baseAlpha 0.34` |
| chevron 线条 | SF Symbol `chevron.compact.*`，`font(size: 15, weight: .regular)` | `Path` 描边，`strokeWidth 1.5dp`，圆头圆角 |
| 圆点 | `Circle` 直径 `3` | `drawCircle` 半径 `1.5dp` |
| 状态过渡 | `isContinuous` 由 `updateRepeat/stopRepeat` 用 spring 切换 | `setState` 各分量 `ValueAnimator 160ms` `DecelerateInterpolator` |

> 连续态由 §3.4 阶段 B 的触发/退出驱动：iOS 在 `updateRepeat` 进入连续时置 `isContinuous = true`、`stopRepeat` 复位；Android 在 `updateCursorDrag` / `cursorRepeatRunnable` 中切换 `cursorContinuous` 并调用 `refreshDirectionHints()`。


---

## 4. 上拉切换文字输入

- **热区**：面板顶端两侧 + 左右两侧 margin 共四块透明热区（`Color.black @ 0.0001`，可命中但不可见）。
  - 顶端中间留 `140` 宽的麦克风保护区（不接管手势）。
  - 各热区上边缘 / 外边缘向外溢出 `10`，增加触控容忍度。
- **手势**：在热区上向上拖拽。
  - 拖动中面板按 `pullProgress` 上移并淡出（`composerLift = 56`）。
  - 上拉量 > `composerLift × 0.55` → 展开文字输入栏（`inputVisible = true`），轻触感（`.light`）。
  - 未过阈值 → 弹簧回弹复位。
- **防弹跳**：热区作为 `.offset` 之后的 overlay 保持静止，不随面板移动，避免手势宿主位移导致 SwiftUI 取消/重启手势造成的跳动闪烁。

### 文字输入栏
- 多行 TextField（1–4 行）+ 发送按钮。
- 在输入栏上向下拖拽（位移 > `28`）→ 收起，回到语音面板。

---

## 5. 关键参数（TalkUX）

| 参数 | 值 | 含义 |
|---|---|---|
| `cursorActivation` | `28` | 进入光标模式的最小拖动距离（防误触死区） |
| `cursorStep` | `24` | 水平棘轮步长（每字符） |
| `swipeTrigger` | `32` | 上下切行的松手触发距离 |
| `verticalBias` | `1.8` | 锁定上下轴所需的垂直占优倍数 |
| `continuousThreshold` | 动态（回退 `96`） | 进入连续移动的偏移阈值 = 麦克风中心→侧按钮中心距离，随设备宽度自适应（见 §3.4） |
| `repeatSlow` | `0.2s` | 连续移动最慢间隔 |
| `repeatFast` | `0.04s` | 连续移动最快间隔 |
| `tapMaxDuration` | `0.18s` | 轻点的最大按压时长 |
| `doubleTapMax` | `0.35s` | 双击判定的最大间隔 |
| `composerLift` | `56` | 上拉切换时面板上移位移 |
| `holdDuration` | `0.75s` | 长按按钮的触发时长 |

---

## 6. 触感反馈

| 场景 | iOS 反馈 | Android 对应 |
|---|---|---|
| 光标移动每步 | `.light` | `KEYBOARD_TAP` |
| 进入光标模式 | `.rigid` | — |
| 上下切行 | `.medium` + 延迟 `.light` | `KEYBOARD_TAP` 立即 + 延迟 55ms |
| 麦克风开始说话 | `.light` | `KEYBOARD_TAP` |
| 上拉切换文字输入 | `.light` | `KEYBOARD_TAP` |
| 按钮长按完成 | `Notification.success` | `LONG_PRESS` |
| 按钮轻点 / 发送动作 | `.light` | — |

> 注：iOS 模拟器不支持 Taptic Engine，触感只能在真机上验证。

---

## 7. 文案

| 状态 | 文案 |
|---|---|
| 空闲（标准） | 按住说话 |
| 空闲（英文模式） | 请说英文 |
| 录音中（标准） | 正在听… |
| 录音中（英文） | 请说英文 |
| 水平光标模式 | ← 拖动移动光标 → |
| 垂直光标模式 | ↑ 上滑松手切行 ↓ |
| 单击语音按钮 | （toast）再按一次进入英文输入 |
| 长按清空 | （toast）已清空 |

---

## 8. 平台差异（按各自平台标准保留）

以下两项在两端**有意保持不同**，属于尊重各平台原生质感的设计差异，不需要强行对齐。各自方案即为该平台的标准。

### 8.1 面板圆角曲率

| 平台 | 实现 | 曲率类型 |
|---|---|---|
| iOS | `RoundedRectangle(cornerRadius: 34, style: .continuous)` | 连续曲率（squircle），圆角过渡更柔和 |
| Android | `MaterialCardView` `cardCornerRadius = 34dp`（`composer_corner_radius`） | 标准圆弧（正圆角），与 Material 体系一致 |

半径数值两端都是 `34`，但 iOS 的连续曲率与 Android 的正圆弧在视觉上略有不同——这是平台差异，保留。

### 8.2 左右上角装饰

| 平台 | 方案 |
|---|---|
| iOS | 面板左上 / 右上各一条 `CornerArc` 同心弧线（半径 `34`、`textTertiary @ 0.28`、线宽 `1.8`、右侧镜像），向外延伸圆角曲线，仅装饰、不参与命中测试。 |
| Android | 无弧线装饰。面板仅靠 `MaterialCardView` 的 `1dp` 全周描边（`strokeColor = line`）勾勒轮廓。 |

iOS 的角落弧线为面板增加了一处精致的视觉细节；Android 遵循 Material 卡片的整体描边风格。两套方案各为该平台标准，保留。

### 8.3 标题区「更多」按钮图标朝向

| 平台 | 图标 | 系统库 | 朝向 |
|---|---|---|---|
| iOS | `ellipsis` | SF Symbols | 横向三点 `⋯` |
| Android | `ic_more_vert` | Material Icons（more_vert） | 纵向三点 `⋮` |

「更多 / 溢出菜单」在两端朝向不同，是各自平台的原生约定：iOS 全系统（Safari、邮件等）的更多惯例为横向三点；Android Material Design 的 overflow menu（kebab 菜单）标准为纵向三点。用户在各自系统看到的就是其熟悉的朝向，**有意遵循各平台标准，不强行统一**。

