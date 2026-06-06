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
        case .webrtc: return L.t("WebRTC P2P", "WebRTC P2P")
        case .websocket: return L.t("WebSocket 中继", "WebSocket Relay")
        }
    }

    var note: String {
        switch self {
        case .webrtc:
            return L.t("优先直连，延迟更低；在公共 Wi-Fi 下成功率受网络环境影响。",
                       "Prefers a direct connection with lower latency; success rate on public Wi-Fi depends on the network.")
        case .websocket:
            return L.t("所有业务消息走服务器中继；公网与受限网络更稳定。",
                       "All traffic is relayed through the server; more stable on public or restricted networks.")
        }
    }
}

/// 远程桌面采集帧率。
enum ScreenFPS: String, CaseIterable, Identifiable {
    case fps12 = "12"
    case fps18 = "18"
    case fps24 = "24"
    case fps30 = "30"
    var id: String { rawValue }
    var label: String { "\(rawValue) FPS" }
    var value: Int { Int(rawValue) ?? 24 }
}

/// 远程桌面视频编码器。
enum ScreenCodec: String, CaseIterable, Identifiable {
    case h264
    case vp8
    case vp9
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h264: return "H.264"
        case .vp8:  return "VP8"
        case .vp9:  return "VP9"
        }
    }
    var note: String {
        switch self {
        case .h264:
            return L.t("支持硬编码，延迟最低，屏幕文字最清晰。",
                       "Hardware encode supported. Lowest latency, sharpest text.")
        case .vp8:
            return L.t("软编码（libvpx），压缩率比 H.264 低约 15–20%，延迟中等。",
                       "Software encode (libvpx). ~15-20% worse compression than H.264, moderate latency.")
        case .vp9:
            return L.t("软编码（libvpx），压缩率比 H.264 高约 30%，但编码延迟较高，文字可能发糊。",
                       "Software encode (libvpx). ~30% better compression than H.264, but higher encoding latency. Text may appear soft.")
        }
    }
}

/// 远程桌面输出分辨率缩放（相对于视口原始尺寸）。
enum ScreenScale: String, CaseIterable, Identifiable {
    case p100 = "100"
    case p80 = "80"
    case p75 = "75"
    case p60 = "60"
    case p50 = "50"
    var id: String { rawValue }
    var label: String { "\(rawValue)%" }
    var factor: CGFloat { CGFloat(Int(rawValue) ?? 100) / 100.0 }
}

/// 远程桌面画质偏好。disabled=画质优先不降级。
enum ScreenQuality: String, CaseIterable, Identifiable {
    case disabled
    case maintainResolution
    case balanced
    var id: String { rawValue }
    var label: String {
        switch self {
        case .disabled:            return L.t("画质优先", "Quality first")
        case .maintainResolution:  return L.t("保持分辨率", "Keep resolution")
        case .balanced:            return L.t("平衡", "Balanced")
        }
    }
}

/// 拖动光标上/下移到首行或末行边界时的行为。
/// macOS 原生在首行再上移会跳到全文开头、末行再下移会跳到全文结尾。
enum CursorBoundaryMode: String, CaseIterable, Identifiable {
    case native  // 系统默认：到边界跳到全文开头/结尾
    case stop    // 到首/末行后停住不动
    case wrap    // 循环：首行再上跳到末行，末行再下跳到首行

    var id: String { rawValue }
    var label: String {
        switch self {
        case .native: return L.t("系统默认（跳到开头/结尾）", "System default (jump to start/end)")
        case .stop:   return L.t("停在首/末行", "Stop at first/last line")
        case .wrap:   return L.t("循环到另一端", "Wrap to the other end")
        }
    }
    var note: String {
        switch self {
        case .native:
            return L.t("保持 macOS 原生行为：在第一行继续上移会跳到全文开头，最后一行继续下移会跳到全文结尾。",
                       "Keeps the native macOS behavior: moving up on the first line jumps to the very start, and down on the last line jumps to the very end.")
        case .stop:
            return L.t("光标到达首行或末行后，继续上/下移将被忽略，不再跳到开头/结尾（需辅助功能权限）。",
                       "Once the caret reaches the first or last line, further up/down moves are ignored instead of jumping to the start/end (requires Accessibility permission).")
        case .wrap:
            return L.t("在首行继续上移会跳到末行，在末行继续下移会跳到首行（需辅助功能权限）。",
                       "Moving up on the first line jumps to the last line, and down on the last line jumps to the first line (requires Accessibility permission).")
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
        static let screenFPS = "screen.fps"
        static let screenCodec = "screen.codec"
        static let screenScale = "screen.scale"
        static let debugHotZones = "debug.hotZones"
        static let disableDynamicBitrate = "screen.disableDynamicBitrate"
        static let screenQuality = "screen.quality"
        static let cursorBoundary = "cursor.boundaryMode"
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
    /// 拖动光标到首/末行边界时的行为。
    /// 调试：用半透明颜色显示所有隐藏热区。
    @Published var debugHotZones: Bool {
        didSet { defaults.set(debugHotZones, forKey: Key.debugHotZones) }
    }
    /// 禁用 WebRTC 动态码率调整，直接以目标码率编码（默认关闭=自适应）。
    @Published var disableDynamicBitrate: Bool {
        didSet { defaults.set(disableDynamicBitrate, forKey: Key.disableDynamicBitrate) }
    }
    /// 远程桌面输出分辨率缩放（默认 100%=原始尺寸）。
    @Published var screenScale: ScreenScale {
        didSet { defaults.set(screenScale.rawValue, forKey: Key.screenScale) }
    }
    /// 远程桌面视频编码器（默认 H.264）。
    @Published var screenCodec: ScreenCodec {
        didSet { defaults.set(screenCodec.rawValue, forKey: Key.screenCodec) }
    }
    /// 远程桌面画质偏好（默认 disabled=画质优先）。
    @Published var screenQuality: ScreenQuality {
        didSet { defaults.set(screenQuality.rawValue, forKey: Key.screenQuality) }
    }
    /// 远程桌面采集帧率（默认 18）。
    @Published var screenFPS: ScreenFPS {
        didSet { defaults.set(screenFPS.rawValue, forKey: Key.screenFPS) }
    }
    @Published var cursorBoundary: CursorBoundaryMode {
        didSet { defaults.set(cursorBoundary.rawValue, forKey: Key.cursorBoundary) }
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
        debugHotZones = defaults.bool(forKey: Key.debugHotZones)
        disableDynamicBitrate = defaults.bool(forKey: Key.disableDynamicBitrate)
        let scaleRaw = defaults.string(forKey: Key.screenScale) ?? ScreenScale.p100.rawValue
        screenScale = ScreenScale(rawValue: scaleRaw) ?? .p100
        let codecRaw = defaults.string(forKey: Key.screenCodec) ?? ScreenCodec.h264.rawValue
        screenCodec = ScreenCodec(rawValue: codecRaw) ?? .h264
        let qualRaw = defaults.string(forKey: Key.screenQuality) ?? ScreenQuality.disabled.rawValue
        screenQuality = ScreenQuality(rawValue: qualRaw) ?? .disabled
        let fpsRaw = defaults.string(forKey: Key.screenFPS) ?? ScreenFPS.fps18.rawValue
        screenFPS = ScreenFPS(rawValue: fpsRaw) ?? .fps18
        let boundaryRaw = defaults.string(forKey: Key.cursorBoundary) ?? CursorBoundaryMode.native.rawValue
        cursorBoundary = CursorBoundaryMode(rawValue: boundaryRaw) ?? .native
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
