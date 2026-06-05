import SwiftUI

enum AppColor {
    static let bg = Color(hex: 0xF6F8FA)
    static let surface = Color.white
    static let surfaceAlt = Color(hex: 0xEEF2F5)
    static let surfaceActive = Color(hex: 0xE8F0FF)
    static let line = Color(hex: 0xD9E0EA)
    static let accent = Color(hex: 0x2D6CDF)
    static let accentStrong = Color(hex: 0x1F55B8)
    static let accentSoft = Color(hex: 0xDDE9FF)
    static let textPrimary = Color(hex: 0x17212F)
    static let textSecondary = Color(hex: 0x5A6878)
    static let textTertiary = Color(hex: 0x8C98A6)
    static let statusConnectedBg = Color(hex: 0xE4F4EA)
    static let statusConnectedText = Color(hex: 0x236B45)
    static let statusIdleBg = Color(hex: 0xEDF1F4)
    static let statusIdleText = Color(hex: 0x64717F)
    static let messageBubble = Color(hex: 0xE1EBFF)
    static let danger = Color(hex: 0xD14343)
    /// 远程屏幕「幕布」占位底色（深灰，便于测试时辨识窗口范围；接入真实视频前使用）。
    static let videoSurface = Color(hex: 0x1E2024)
    static let videoMinimap = Color(hex: 0x303338)
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255,
            green: Double((hex >> 8) & 0xff) / 255,
            blue: Double(hex & 0xff) / 255,
            opacity: alpha
        )
    }
}

extension View {
    func panel(cornerRadius: CGFloat = 22) -> some View {
        background(AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppColor.line, lineWidth: 1)
            )
    }
}
