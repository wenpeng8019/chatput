import Foundation
import Combine

/// 信令服务器运行模式。
enum SignalingMode: String, CaseIterable, Identifiable {
    case builtIn   // 本地内置原生服务器（局域网）
    case external  // 连接外部地址（公网远程）

    var id: String { rawValue }
    var label: String {
        switch self {
        case .builtIn:  return "本地内置（局域网）"
        case .external: return "外部地址（公网）"
        }
    }
}

/// 手机与桌面之间的业务传输方式。
enum TransportMode: String, CaseIterable, Identifiable {
    case webrtc
    case websocket

    var id: String { rawValue }
    var label: String {
        switch self {
        case .webrtc: return "WebRTC P2P"
        case .websocket: return "WebSocket 中继"
        }
    }

    var note: String {
        switch self {
        case .webrtc:
            return "优先直连，延迟更低；在公共 Wi-Fi 下成功率受网络环境影响。"
        case .websocket:
            return "所有业务消息走服务器中继；公网与受限网络更稳定。"
        }
    }
}

/// 用户配置，持久化到 UserDefaults。修改后通过 `didApply` 通知协调器重连。
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Key {
        static let mode = "signaling.mode"
        static let transport = "transport.mode"
        static let listenPort = "signaling.listenPort"
        static let ipOverride = "signaling.ipOverride"
        static let externalURL = "signaling.externalURL"
        static let language = "app.language"
    }

    /// 配置发生影响连接的变更时触发（由协调器订阅以重启/重连）。
    let didApply = PassthroughSubject<Void, Never>()

    @Published var mode: SignalingMode {
        didSet { defaults.set(mode.rawValue, forKey: Key.mode) }
    }
    @Published var transport: TransportMode {
        didSet { defaults.set(transport.rawValue, forKey: Key.transport) }
    }
    /// 内置服务器监听端口。
    @Published var listenPort: Int {
        didSet { defaults.set(listenPort, forKey: Key.listenPort) }
    }
    /// 对外展示/写入二维码的 IP；为空表示自动探测局域网 IP。
    @Published var ipOverride: String {
        didSet { defaults.set(ipOverride, forKey: Key.ipOverride) }
    }
    /// 外部模式的完整 ws 地址，如 ws://example.com:8080。
    @Published var externalURL: String {
        didSet {
            defaults.set(Self.normalizeExternalURL(externalURL), forKey: Key.externalURL)
        }
    }
    /// 界面语言。
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Key.language) }
    }
    /// 开机自启动（直接读写系统状态，不持久化到 UserDefaults）。
    @Published var launchAtLogin: Bool {
        didSet { LoginItem.setEnabled(launchAtLogin) }
    }

    private let defaults = UserDefaults.standard

    private init() {
        let raw = defaults.string(forKey: Key.mode) ?? SignalingMode.builtIn.rawValue
        mode = SignalingMode(rawValue: raw) ?? .builtIn
        let transportRaw = defaults.string(forKey: Key.transport) ?? TransportMode.webrtc.rawValue
        transport = TransportMode(rawValue: transportRaw) ?? .webrtc
        let port = defaults.integer(forKey: Key.listenPort)
        listenPort = port == 0 ? 8080 : port
        ipOverride = defaults.string(forKey: Key.ipOverride) ?? ""
        let normalizedExternalURL = Self.normalizeExternalURL(defaults.string(forKey: Key.externalURL) ?? "")
        externalURL = normalizedExternalURL
        defaults.set(normalizedExternalURL, forKey: Key.externalURL)
        let lang = defaults.string(forKey: Key.language) ?? AppLanguage.system.rawValue
        language = AppLanguage(rawValue: lang) ?? .system
        launchAtLogin = LoginItem.isEnabled
    }

    /// 内置模式下对外广播的 IP（手动覆盖优先，否则自动探测）。
    var advertisedHost: String {
        let trimmed = ipOverride.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return NetworkInfo.primaryLANIPv4() ?? "127.0.0.1"
    }

    /// 内置模式下当前可对外广播的主机地址；拿不到局域网地址时返回 nil。
    var resolvedAdvertisedHost: String? {
        let trimmed = ipOverride.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return NetworkInfo.primaryLANIPv4()
    }

    /// 桌面端（host）本地用于连接信令的 URL。
    var hostConnectURL: String {
        switch mode {
        case .builtIn:  return "ws://127.0.0.1:\(listenPort)"
        case .external: return Self.normalizeExternalURL(externalURL)
        }
    }

    /// 写入二维码、供手机连接的 URL。
    var advertisedURL: String {
        switch mode {
        case .builtIn:  return "ws://\(advertisedHost):\(listenPort)"
        case .external: return Self.normalizeExternalURL(externalURL)
        }
    }

    /// 规范化外部地址：补全缺失的 ws:// 前缀；https/http 映射为 wss/ws。
    /// 若为 ws 且未显式端口，默认补 8080。
    static func normalizeExternalURL(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "" }
        let lower = trimmed.lowercased()
        let normalized: String
        if lower.hasPrefix("ws://") || lower.hasPrefix("wss://") {
            normalized = trimmed
        } else if lower.hasPrefix("https://") {
            normalized = "wss://" + trimmed.dropFirst("https://".count)
        } else if lower.hasPrefix("http://") {
            normalized = "ws://" + trimmed.dropFirst("http://".count)
        } else {
            normalized = "ws://" + trimmed
        }

        guard var comps = URLComponents(string: normalized) else { return normalized }
        if comps.scheme?.lowercased() == "ws", comps.port == nil {
            comps.port = 8080
            return comps.string ?? normalized
        }
        return normalized
    }

    /// 提交配置变更，触发协调器重连。
    func apply() {
        didApply.send()
    }
}
