import AppKit
import ApplicationServices
import CoreGraphics

/// 文字注入：把识别文本写入剪贴板，再模拟 Cmd+V 粘贴到当前焦点输入框，随后还原剪贴板。
/// 需要「辅助功能」权限（CGEvent 注入）。
final class TextInjector {
    func inject(_ text: String) {
        guard !text.isEmpty else { return }
        let pb = NSPasteboard.general
        let saved = pb.string(forType: .string)

        pb.clearContents()
        pb.setString(text, forType: .string)

        paste()

        // 粘贴完成后还原剪贴板。
        DispatchQueue.main.asyncAfter(deadline: .now() + AppConfig.Timing.clipboardRestore) {
            pb.clearContents()
            if let saved = saved { pb.setString(saved, forType: .string) }
        }
    }

    private func paste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey = AppConfig.KeyCode.v
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - 动作注入

    /// 支持的操作按键。
    enum Action: String {
        case enter      // 回车（触发执行/换行）
        case shiftEnter // Shift+回车（多数聊天软件为换行）
        case backspace  // 退格（删除前一个字符）
        case selectAll  // 全选（Cmd+A）
        case clear      // 清空输入（全选 + 退格）
        case cursorLeft  // 光标左移一个字符
        case cursorRight // 光标右移一个字符
        case cursorUp    // 光标上移一行
        case cursorDown  // 光标下移一行
    }

    /// 执行一个操作。
    func perform(_ action: Action) {
        switch action {
        case .enter:
            tapKey(AppConfig.KeyCode.return)
        case .shiftEnter:
            tapKey(AppConfig.KeyCode.return, flags: .maskShift)   // Shift+Return
        case .backspace:
            tapKey(AppConfig.KeyCode.delete)
        case .selectAll:
            tapKey(AppConfig.KeyCode.a, flags: .maskCommand)   // Cmd+A
        case .clear:
            tapKey(AppConfig.KeyCode.a, flags: .maskCommand)   // Cmd+A
            tapKey(AppConfig.KeyCode.delete)
        case .cursorLeft:
            tapKey(AppConfig.KeyCode.leftArrow)
        case .cursorRight:
            tapKey(AppConfig.KeyCode.rightArrow)
        case .cursorUp:
            moveVertically(up: true)
        case .cursorDown:
            moveVertically(up: false)
        }
    }

    // MARK: - 上下行边界处理

    /// 根据用户设置处理光标上/下移：在首/末行边界时可选择停住或循环。
    private func moveVertically(up: Bool) {
        let mode = AppSettings.shared.cursorBoundary
        let arrow = up ? AppConfig.KeyCode.upArrow : AppConfig.KeyCode.downArrow

        // 系统默认，或拿不到光标行信息（如非原生输入框）时，直接发方向键。
        guard mode != .native, let pos = caretLinePosition() else {
            tapKey(arrow)
            return
        }

        let atBoundary = up ? pos.atFirst : pos.atLast
        guard atBoundary else {
            tapKey(arrow)
            return
        }

        switch mode {
        case .native:
            tapKey(arrow)
        case .stop:
            break   // 已在首/末行，忽略本次移动
        case .wrap:
            // 首行再上 → 跳到全文结尾（末行）；末行再下 → 跳到全文开头（首行）。
            if up {
                tapKey(AppConfig.KeyCode.downArrow, flags: .maskCommand)
            } else {
                tapKey(AppConfig.KeyCode.upArrow, flags: .maskCommand)
            }
        }
    }

    /// 读取当前焦点输入框中插入点是否位于首行/末行。
    /// 依赖辅助功能文本属性；不支持时返回 nil（调用方退回原生行为）。
    private func caretLinePosition() -> (atFirst: Bool, atLast: Bool)? {
        let system = AXUIElementCreateSystemWide()
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focusedRef = focused else { return nil }
        let element = focusedRef as! AXUIElement

        // 插入点字符索引。
        var rangeRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rv = rangeRef else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rv as! AXValue, .cfRange, &range) else { return nil }

        // 文本总字符数。
        var countRef: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &countRef) == .success,
              let total = countRef as? Int else { return nil }
        guard total >= 0 else { return nil }

        func line(forCharIndex index: Int) -> Int? {
            var i = index
            guard let arg = CFNumberCreate(nil, .intType, &i) else { return nil }
            var result: AnyObject?
            guard AXUIElementCopyParameterizedAttributeValue(
                    element,
                    kAXLineForIndexParameterizedAttribute as CFString,
                    arg, &result) == .success,
                  let lineNum = result as? Int else { return nil }
            return lineNum
        }

        let caretIndex = max(0, min(range.location, max(0, total - 1)))
        let lastIndex = max(0, total - 1)
        guard let firstLine = line(forCharIndex: 0),
              let caretLine = line(forCharIndex: caretIndex),
              let lastLine = line(forCharIndex: lastIndex) else { return nil }

        return (atFirst: caretLine <= firstLine, atLast: caretLine >= lastLine)
    }

    /// 模拟一次按键（按下 + 抬起），可带修饰键。
    private func tapKey(_ keyCode: CGKeyCode, flags: CGEventFlags = []) {
        let src = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

    // MARK: - 权限

    static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    @discardableResult
    static func ensureAccessibilityPermission(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
