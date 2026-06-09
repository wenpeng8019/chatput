# 思路避坑经验：案例一 — Android 动态添加 View 定位问题

## 背景

ChatActivity 需要在"焦点会话交互面板"的麦克风按钮四周动态创建四个可点击方块（D-pad 上/下/左/右），只在桌面端输入不可用时显示，正常模式移除。

**需求**：四个方块各为 r×r（r = 麦克风按钮半径 ≈ 136px），分别紧贴在按钮的上/下/左/右边，水平/垂直居中。

**预期布局**：十字形 D-pad，方块与中心圆重叠半边长。

## 耗时

约 3 小时，超过之前所有功能开发时间之和。

## 尝试过的方案（全部失败或部分失败）

| # | 父容器 | 定位方式 | 结果 | 失败原因 |
|---|--------|----------|------|----------|
| 1 | inner ConstraintLayout | `ViewGroup.MarginLayoutParams(leftMargin, topMargin)` | 四块堆在 (0,0) | ConstraintLayout 不认 MarginLayoutParams |
| 2 | inner ConstraintLayout | `ConstraintLayout.LayoutParams` + 反射设约束字段 | 同上 | 动态添加子 View 后约束求解时机不可靠 |
| 3 | inner ConstraintLayout | `ConstraintLayout.LayoutParams` + 直接属性赋值 | 同上 | 同上 |
| 4 | composer_card (FrameLayout) | `FrameLayout.LayoutParams(leftMargin, topMargin)` | 位置偏移 | 坐标计算未考虑 inner CL padding + MaterialCardView 裁剪 |
| 5 | composer_card + clipChildren | `FrameLayout.LayoutParams` | 偏移不对 | getLocationInWindow 和 FrameLayout leftMargin 起点不一致 |
| 6 | inner ConstraintLayout | `ViewGroup.LayoutParams` + `translationX/Y` | 不对称，偏右下 | 用 `btn.left/top` 但没对齐 btn 中心 |
| 7 | inner ConstraintLayout | `translationX/Y` + 居中修正 | 位置对了但方块太小 | r = btn.width/2 使方块面积只有 btn 的 1/4 |
| 8 | inner ConstraintLayout | `translationX/Y` + r = btn.width | 布局被撑乱 | 方块太大与面板内其他控件重叠 |

## 最终方案（第 9 次尝试成功）

```kotlin
// 父容器：root ConstraintLayout（全屏，无 padding，零干扰）
val root = binding.root
root.clipChildren = false

// 坐标：getLocationOnScreen 取 btn 和 root 的绝对屏幕坐标
btn.getLocationOnScreen(btnLoc)
root.getLocationOnScreen(rootLoc)
val bx = (btnLoc[0] - rootLoc[0]).toFloat()
val by = (btnLoc[1] - rootLoc[1]).toFloat()

// 定位：translationX/Y（纯像素偏移，完全绕过 layout 系统）
// 方块大小 r = btn.width / 2，向内偏移 h = r / 2 实现与中心重叠
val r = btn.width / 2
val h = r / 2f
listOf(
    Triple("cursorUp",    bx + h,   by - h),
    Triple("cursorDown",  bx + h,   by + btn.height - h),
    Triple("cursorLeft",  bx - h,   by + h),
    Triple("cursorRight", bx + btn.width - h, by + h),
)
```

## 根因分析

**唯一根因**：Android View 定位有三套独立机制，彼此不兼容。

| 机制 | 生效条件 | 本场景可行性 |
|------|----------|------------|
| `MarginLayoutParams` (leftMargin/topMargin) | 父容器是 FrameLayout / LinearLayout | 可用，但 ConstraintLayout 不认 |
| `ConstraintLayout.LayoutParams` (约束字段) | 父容器是 ConstraintLayout | 理论可用，动态添加时约束求解不可靠 |
| `translationX / translationY` | 任何父容器 | **最可靠——纯像素偏移，绕过所有 layout 系统** |

**关键失误**：始终没在第一轮失败后停下来验证"ConstraintLayout 到底接受什么 LayoutParams"。如果第一轮失败后就检查这个假设，后面 7 轮都不用做。

## 核心教训

1. **先验证假设，再改代码**。这个问题的每次部署-测试只要 30 秒，但 8 次失败的总成本是 3 小时。第一轮失败后应该立刻确认"父容器到底认不认我传的 LayoutParams"。

2. **日志比肉眼快**。一旦加上日志确认坐标计算是对的，问题就变成"父容器为什么不认这个坐标"，而不是"换什么参数组合能撞对"。

3. **简单问题不要复杂化**。就是在屏幕上放 4 个方块。root + absolute position + translation 是最短路——不需要考虑约束链、padding 补偿、切 parent。

4. **花 5 分钟查正确范式能省 3 小时**。Android 动态添加 View 的正确范式是 root + translation，不是往嵌套 ConstraintLayout 里塞 MarginLayoutParams。动手前先搜一下。

---

# 思路避坑经验：案例二 — WebRTC 分辨率变化后视频不刷新 / 黑边

## 背景

远程桌面支持显示缩放（1:1 / 0.9 / 0.8 / 0.75），手机选择缩放后请求更大视口，桌面裁剪更多内容编码发送，手机自然显示为缩小。

## 现象

1. 动态画面缩放：正常
2. 静态画面缩放：右下黑边，画面不更新；内容一动跳到正确比例
3. 拖拽视口来回跳（缓存旧帧和 SCStream 新帧交替）

## 耗时：约 5 小时

## 尝试过的方案

| # | 方案 | 失败原因 |
|---|------|----------|
| 1 | 缓存帧重裁 + 像素翻转 | 几个像素不足改变编码器判定 |
| 2 | 时间门 (>200ms) | 缩放场景首帧被拦 |
| 3 | CGWindowListCreateImage 系统截图 | CGWindowID 参数错误 |
| 4 | toggle 视频轨强制关键帧 | 画面闪黑 |
| 5 | 线程调度 `onFrame` | WebRTC 多线程本来就支持 |
| 6 | 每帧调 `raiseVideoBitrate` | 率控不是根因 |
| 7 | 不改分辨率也强推 `adaptOutputFormat` | 没重协商对端不解码 |

## 最终方案

```swift
// WebRTCManager: 分辨率变化时先协商再改编码器
if w != lastAdaptW || h != lastAdaptH {
    renegotiate()  // 先让对端解码器知道要换分辨率
    DispatchQueue.main.asyncAfter(.now() + 0.15) {
        source.adaptOutputFormat(...)  // 再改编码输出（不跳帧）
    }
}

// WindowCapturer: 尺寸变只推一帧（等重协商完），位置变立即推
if sizeChanged {
    DispatchQueue.main.asyncAfter(.now() + 0.25) { refreshFromCacheIfNeeded() }
} else {
    refreshFromCacheIfNeeded()
}
```

## 根因

**WebRTC 分辨率变化 = 两件事：改编码器 + 重协商，缺一不可。**
`adaptOutputFormat` 只改编码输出尺寸，对端解码器不知道。必须 `renegotiate()` 发新 SDP 通知手机。

**第二次搞砸的原因**：为修"拖拽跳动"加的时间门 >200ms，把缩放场景首帧也拦了。之后 3 个多小时全在猜编码器内部行为，没一个是正解。

## 核心教训

1. **改分辨率 = 先协商后编码，顺序不能错**。
2. **全局开关（时间门）要区分场景**。`sizeChanged` 比时间阈值可靠。
3. **编码器"跳帧"不是魔法**——花 3 小时猜内部行为，最后发现是 SDP 没通知对端。

---

# 思路避坑经验：案例三 — Android ring shape 公式认死理

## 背景

对齐 iOS ↔ Android 侧边按钮长按进度环（ProgressBar + ring shape），使其半径一致。

## 现象

Android 端环明显大于按钮、接近中心 orb_halo 半径（53dp）。iOS 端反复在贴合按钮（28pt）和超出按钮（53pt）之间来回改。

## 耗时：约 40 分钟，改 iOS 端约 8 次

## 尝试过的值

| # | iOS 半径 | iOS 线宽 | 外径 | 依据 |
|---|---------|---------|------|------|
| 1 | 39 | 3.9 | ~41pt | 原始代码 |
| 2 | 26 | 4 | 28pt | 贴合按钮（自认对） |
| 3 | 25.67 | 4.67 | 28pt | 精确对齐（自认对） |
| 4 | 48.6 | 8.8 | 53pt | 对齐 orb_halo（用户要求） |
| 5 | 25.67 | 4.67 | 28pt | 又改回贴合按钮 |
| 6 | 51.5 | 3 | 53pt | 大半径+细线 |
| 7 | 25.67 | 4.67 | 28pt | 再次改回贴合按钮 |
| 8 | 49 | 4.67 | ~51.3pt | 最终对齐 Android 实际值 |

## 最终方案

Android ring shape 公式是 `innerRadius = width / innerRadiusRatio`（不是自以为的 `width / (2 × ratio)`）：

```
56dp ProgressBar + innerRadiusRatio=1.2 + thicknessRatio=12
→ inner = 56/1.2 = 46.67dp, thickness = 56/12 = 4.67dp, outer = 51.33dp
```

且按钮有 `clipChildren=false`，环画出 ProgressBar 边界外依然可见。

## 根因

**自编了一个公式然后死守不放。** 把 Android 官方文档的 `innerRadius = width / ratio` 自行"修正"为 `width / (2 × ratio)`，基于这个错误公式反复改 iOS 端值。用户反复说"Android 就是大环"，不去验证公式对不对，而是继续在错误方向上微调。

## 核心教训

1. **被用户否定 2 次以上，先验证前提假设，不要继续改代码。** 用户说大环 → 我说的公式算出来不是 → 应该立刻查公式对不对，而不是反复改输出。
2. **官方文档/源码优先于心算。** 自认 `width / (2 × ratio)` "显然对"，实际上 Android 文档写的就是 `width / ratio`。
3. **视觉证据 > 代码推断。** 用户肉眼看到大环，我基于代码算出小环，信代码不信眼睛。
