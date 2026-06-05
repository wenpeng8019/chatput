import Foundation
import CoreGraphics
import AppKit

/// 在采集窗口上模拟鼠标点击与滚轮事件（触控转鼠标 2.0）。
///
/// 手机发送窗口逻辑坐标，由本类按窗口的 CG 全局位置 + 标题栏高度补偿
/// 换算为屏幕坐标，再通过 CGEvent 推入系统事件流。
final class PointerInjector {
    private var windowFrame: CGRect = .zero      // CG 全局坐标（左上原点，含标题栏）
    /// 窗口内容区左上角在屏幕坐标系中的 Y 偏移（标题栏高度）。
    private var contentOriginY: CGFloat = 0
    /// 供上层注入日志回调。
    var onLog: ((String) -> Void)?

    /// 更新目标窗口几何信息（每次采集启动时调用）。
    func updateWindow(frame: CGRect, scale: CGFloat, contentLogicalH: CGFloat) {
        self.windowFrame = frame
        // SCContentFilter(desktopIndependentWindow:) 采集的是窗口内容区（不含标题栏），
        // 而 windowFrame 是整个窗口含标题栏的 frame。两者 Y 差值即为标题栏高度。
        self.contentOriginY = frame.origin.y + max(0, frame.height - contentLogicalH)
        onLog?("pointer: winFrame=\(frame) contentH=\(contentLogicalH) → contentOriginY=\(contentOriginY)")
    }

    /// 窗口逻辑坐标 → 屏幕 CG 坐标（补偿标题栏偏移）。
    private func screenPoint(x: Int, y: Int) -> CGPoint {
        let pt = CGPoint(x: windowFrame.origin.x + CGFloat(x),
                         y: contentOriginY + CGFloat(y))
        onLog?("pointer: tap(\(x),\(y)) → screen(\(pt.x),\(pt.y))")
        return pt
    }

    func mouseDown(x: Int, y: Int) {
        let pt = screenPoint(x: x, y: y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    func mouseUp(x: Int, y: Int) {
        let pt = screenPoint(x: x, y: y)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// dx/dy 为像素级滚动量。正值向下/向右。
    func scroll(dx: Int, dy: Int) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        event.setIntegerValueField(.scrollWheelEventScrollCount, value: 1)
        event.post(tap: .cghidEventTap)
    }
}
