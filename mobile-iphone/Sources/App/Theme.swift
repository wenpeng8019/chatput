import UIKit

/// Dynamic color theme matching Android ChatPUT palette.
/// Each color adapts to light/dark mode via UITraitCollection.
enum Theme {

    // MARK: - Background / Surface

    static let bg = dynamic(light: 0xF6F8FA, dark: 0x101418)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A2027)
    static let surfaceAlt = dynamic(light: 0xEEF2F5, dark: 0x222A33)
    static let surfaceActive = dynamic(light: 0xE8F0FF, dark: 0x263D66)

    // MARK: - Accent (blue)

    static let accent = dynamic(light: 0x2D6CDF, dark: 0x7BA9FF)
    static let accentStrong = dynamic(light: 0x1F55B8, dark: 0x5E91ED)
    static let accentSoft = dynamic(light: 0xDDE9FF, dark: 0x263D66)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0x08111F)

    // MARK: - Text

    static let textPrimary = dynamic(light: 0x17212F, dark: 0xEEF2F6)
    static let textSecondary = dynamic(light: 0x5A6878, dark: 0xB8C2CD)
    static let textTertiary = dynamic(light: 0x8C98A6, dark: 0x6B7888)

    // MARK: - Line / Border

    static let line = dynamic(light: 0xD9E0EA, dark: 0x2A3340)

    // MARK: - Status

    static let statusConnectedBg = dynamic(light: 0xE4F4EA, dark: 0x1A3D2A)
    static let statusConnectedText = dynamic(light: 0x236B45, dark: 0x5EDC8A)
    static let statusIdleBg = dynamic(light: 0xEDF1F4, dark: 0x242C35)
    static let statusIdleText = dynamic(light: 0x64717F, dark: 0x8C9AA8)

    // MARK: - Message bubble

    static let messageBubble = dynamic(light: 0xE1EBFF, dark: 0x293E65)
    static let messageBubbleSelf = dynamic(light: 0x2D6CDF, dark: 0x3B6EC7)

    // MARK: - Video / Screen

    static let videoSurface = dynamic(light: 0x1E2024, dark: 0x1E2024)
    static let videoMinimap = dynamic(light: 0x303338, dark: 0x303338)

    // MARK: - Other

    static let danger = dynamic(light: 0xD14343, dark: 0xFF8C8C)

    // MARK: - Helper

    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(rgb: dark)
                : UIColor(rgb: light)
        }
    }
}

extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}
