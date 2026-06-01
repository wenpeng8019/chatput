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
