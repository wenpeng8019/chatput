# 远程桌面：缩放闪烁问题

## 现象

手机端调整屏幕缩放（如 1.0 → 0.75），画面立刻变为正确比例和内容，但内容变化时会闪一下（或右下出现黑边后恢复）。

## 根因

缩放改变视口尺寸 → 桌面端裁剪输出分辨率变化 → WebRTC 编码器需通过 SDP 重协商适配新分辨率。

重协商完成前，新分辨率帧被推入旧配置编码器。重协商完成后 `adaptOutputFormat` 触发编码器状态切换（GOP 重置、码率重分配），下一帧与前一帧的编码输出产生视觉跳变——即"闪"。

静态画面下 SCStream 不产生新帧，因此闪烁被推迟到下一次内容变化或用户操作时才发生。

## 已尝试但不可行的方案

| 方案 | 问题 |
|------|------|
| 重协商后立即推刷新帧 (`onRenegotiationComplete → flushAfterRenegotiation`) | 刷新帧在错误时序推入，产生黑边 |
| 重协商前立即适配编码器 (`adaptOutputFormat` 不等 SDP) | 编码器状态异常，产生黑边 |
| 延迟应用新视口尺寸 (`pendingSize`) | 画面比例不对 |
| 重协商期间丢弃帧 (guard) | 画面冻结 |
| 硬编码延迟 (`asyncAfter 0.15s/0.25s`) | 只能猜测时机，慢网络下失效 |

桌面端无法解决此问题的根本原因：分辨率变化由帧推入触发，编码器适配依赖远端 answer 到达，而帧必须在这期间持续流送。这是一个循环依赖。

## 最终方案

**Android 端过渡平滑**：`ScreenPanelController.onMeta` 检测到桌面端输出分辨率变化（applied w/h 改变）时：

1. `VideoTrack.removeSink(renderer)` — 暂停渲染器接收新帧
2. `SurfaceViewRenderer` 保持显示最后一帧（正确画面）
3. 120ms 后 `addSink(renderer)` — 恢复

编码器切换发生在这 120ms 内，用户只看到画面短暂停顿，新帧无缝接上。

```
缩放 → 桌面推第一帧(新分辨率,旧编码器,画面OK)
     → SDP 重协商(~78ms)
     → 编码器适配完成
     → Android hold 120ms 期间丢弃过渡帧
     → 恢复 → 编码器已稳定 → 画面正常
```

## 关键日志数据

实测于 2026-06-07：

```
桌面端:
  1780811034.177  push:RESIZE 726x1208→968x1610  renegotiate...
  1780811034.255  push:RENEG-DONE adaptOutputFormat(968,1610)
  → 重协商耗时 78ms

Android:
  13:43:54.004  scale 1.0→0.75  vp=(1199,274 484x805)
  13:43:58.373  meta applied=(1199,274 484x805)
  → meta 回传延迟 4.3s（onMeta 仅在 SCStream 帧中调用，静态屏无新帧）
```

## 相关 commit

- `dc744d8` fix: 消除视口 TOCTOU 竞态 + 重协商改为远端 answer 回调
- `3115f52` chore: 清理死代码
