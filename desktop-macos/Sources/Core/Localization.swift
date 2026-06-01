import Foundation

/// 界面语言。`system` 跟随系统语言，否则强制中文 / 英文。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case zh
    case en

    var id: String { rawValue }

    /// 在语言选择器里展示的名称。
    var label: String {
        switch self {
        case .system: return L.t("跟随系统", "Follow System")
        case .zh:     return "中文"
        case .en:     return "English"
        }
    }
}

/// 轻量本地化助手：`L.t("中文", "English")` 按当前语言返回对应文案。
enum L {
    /// 当前是否使用中文。
    static var isChinese: Bool {
        switch AppSettings.shared.language {
        case .zh: return true
        case .en: return false
        case .system:
            let pref = Locale.preferredLanguages.first ?? "en"
            return pref.hasPrefix("zh")
        }
    }

    static func t(_ zh: String, _ en: String) -> String {
        isChinese ? zh : en
    }
}
