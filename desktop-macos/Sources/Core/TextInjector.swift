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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            pb.clearContents()
            if let saved = saved { pb.setString(saved, forType: .string) }
        }
    }

    private func paste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9 // 'v'
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
        case backspace  // 退格（删除前一个字符）
        case selectAll  // 全选（Cmd+A）
        case clear      // 清空输入（全选 + 退格）
    }

    /// 执行一个操作。
    func perform(_ action: Action) {
        switch action {
        case .enter:
            tapKey(36)                      // Return
        case .backspace:
            tapKey(51)                      // Delete (backspace)
        case .selectAll:
            tapKey(0, flags: .maskCommand)  // Cmd+A
        case .clear:
            tapKey(0, flags: .maskCommand)  // Cmd+A
            tapKey(51)                      // Delete
        }
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
