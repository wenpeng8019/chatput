import UIKit

/// Dynamic color theme: light matches Android palette, dark matches original.
/// Each color adapts via UITraitCollection.
enum Theme {

    // MARK: - Background / Surface

    static let bg = dynamic(light: 0xF6F8FA, dark: 0x1F1F24)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x292929)
    static let surfaceAlt = dynamic(light: 0xEEF2F5, dark: 0x333333)
    static let surfaceActive = dynamic(light: 0xE8F0FF, dark: 0x333333)

    // MARK: - Accent (blue light / orange dark)

    static let accent = dynamic(light: 0x2D6CDF, dark: 0xFF9438)
    static let accentStrong = dynamic(light: 0x1F55B8, dark: 0xE07020)
    static let accentSoft = dynamic(light: 0xDDE9FF, dark: 0x3D2A1A)
    static let onAccent = dynamic(light: 0xFFFFFF, dark: 0xFFFFFF)

    // MARK: - Text

    static let textPrimary = dynamic(light: 0x17212F, dark: 0xFFFFFF)
    static let textSecondary = dynamic(light: 0x5A6878, dark: 0x999999)
    static let textTertiary = dynamic(light: 0x8C98A6, dark: 0x808080)

    // MARK: - Line / Border

    static let line = dynamic(light: 0xD9E0EA, dark: 0x383838)

    // MARK: - Status

    static let statusConnectedBg = dynamic(light: 0xE4F4EA, dark: 0x1A3D2A)
    static let statusConnectedText = dynamic(light: 0x236B45, dark: 0x33CC66)
    static let statusIdleBg = dynamic(light: 0xEDF1F4, dark: 0x333333)
    static let statusIdleText = dynamic(light: 0x64717F, dark: 0x999999)

    // MARK: - Message bubble

    static let messageBubble = dynamic(light: 0xE1EBFF, dark: 0x292929)
    static let messageBubbleSelf = dynamic(light: 0x2D6CDF, dark: 0x2E59DE)

    // MARK: - Video / Screen

    static let videoSurface = dynamic(light: 0x1E2024, dark: 0x1F2124)
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
