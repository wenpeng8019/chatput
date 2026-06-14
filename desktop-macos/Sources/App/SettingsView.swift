import SwiftUI
import AppKit

/// 设置窗口内容：Tab 形式 —— 内置服务 | 外部 | 日志。
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var state = AppState.shared

    /// 本地编辑副本，避免每次输入都触发重连；保存时一次性提交。
    @State private var listenPort: String = String(AppSettings.shared.listenPort)
    @State private var ipOverride: String = AppSettings.shared.ipOverride
    @State private var externalURL: String = AppSettings.shared.externalURL

    var onClose: () -> Void = {}

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label(L.t("通用", "General"), systemImage: "gearshape") }
            screenTab
                .tabItem { Label(L.t("远程桌面", "Screen"), systemImage: "display") }
            builtInTab
                .tabItem { Label(L.t("内置服务", "Built-in"), systemImage: "house") }
            externalTab
                .tabItem { Label(L.t("外部服务", "External"), systemImage: "globe") }
            logTab
                .tabItem { Label(L.t("日志", "Logs"), systemImage: "doc.plaintext") }
        }
        .padding(16)
        .frame(width: 500, height: 420)
    }

    // MARK: - 通用

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(L.t("通用", "General"),
                          subtitle: L.t("语言与启动选项。", "Language and startup options."))

            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Text(L.t("开机自动运行", "Launch at login"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    Toggle("", isOn: $settings.launchAtLogin)
                        .labelsHidden()
                        .toggleStyle(.switch)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text(L.t("自动保存房间", "Auto-save room"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    Toggle("", isOn: $settings.autoSaveRoomId)
                        .labelsHidden()
                        .toggleStyle(.switch)
                    if settings.autoSaveRoomId || !settings.savedRoomId.isEmpty {
                        Text(settings.savedRoomId.isEmpty ? "—" : settings.savedRoomId)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }

                HStack(alignment: .top, spacing: 12) {
                    Text(L.t("传输模式", "Transport"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $settings.transport) {
                            ForEach(TransportMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        .id(settings.language)

                        Text(settings.transport.note)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }

                HStack(alignment: .top, spacing: 12) {
                    Text(L.t("上下行边界", "Up/Down edge"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        Picker("", selection: $settings.cursorBoundary) {
                            ForEach(CursorBoundaryMode.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 260)
                        .id(settings.language)

                        Text(settings.cursorBoundary.note)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()
                }


                HStack(spacing: 12) {
                    Text(L.t("语言", "Language"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: $settings.language) {
                        ForEach(AppLanguage.allCases) { lang in
                            Text(lang.label).tag(lang)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 260)
                    .id(settings.language)
                    Spacer()
                }

            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 远程桌面

    private var screenTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(L.t("远程桌面", "Screen"),
                          subtitle: L.t("远程桌面的采集、编码与交互参数。",
                                        "Capture, encoding and interaction settings for remote screen."))

            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    Text(L.t("优先编码", "Preferred codec"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Picker("", selection: $settings.screenCodec) {
                                ForEach(ScreenCodec.allCases) { c in
                                    Text(c.label).tag(c)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                            if settings.screenCodec != .h264 {
                                Text(L.t("移动端不支持时回退到 H.264", "Falls back to H.264 if unsupported"))
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                        Text(settings.screenCodec.note)
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text(L.t("采集帧率", "FPS"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: $settings.screenFPS) {
                        ForEach(ScreenFPS.allCases) { fps in
                            Text(fps.label).tag(fps)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Spacer()
                }

                HStack(alignment: .top, spacing: 12) {
                    Text(L.t("输出分辨率", "Resolution"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $settings.screenScale) {
                            ForEach(ScreenScale.allCases) { s in
                                Text(s.label).tag(s)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        Text(L.t("缩小桌面图像以节省带宽，手机端自动上采样填满画面。",
                                 "Downscales the desktop image to save bandwidth. The phone upscales to fill the view."))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text(L.t("画质偏好", "Quality"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    Picker("", selection: $settings.screenQuality) {
                        ForEach(ScreenQuality.allCases) { q in
                            Text(q.label).tag(q)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text(L.t("固定码率", "Fixed bitrate"))
                        .font(.system(size: 12))
                        .frame(width: 90, alignment: .leading)
                    Toggle("", isOn: $settings.disableDynamicBitrate)
                        .labelsHidden()
                        .toggleStyle(.switch)
                    Text(L.t("关闭自适应，首帧即清晰",
                             "Disable adaptive bitrate for sharp first frames."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 内置服务

    private var builtInTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(L.t("内置服务（局域网）", "Built-in (LAN)"),
                          subtitle: L.t("在本机运行信令服务器，手机与电脑处于同一局域网时使用。",
                                        "Run the signaling server locally; use it when phone and Mac are on the same LAN."))
            modeBadge(active: settings.mode == .builtIn)

            VStack(alignment: .leading, spacing: 12) {
                field(L.t("监听端口", "Port"), text: $listenPort, placeholder: "8080")
                field(L.t("对外 IP", "Host IP"), text: $ipOverride,
                      placeholder: L.t("留空自动探测", "Auto-detect if empty"))
                Text(L.t("自动探测：", "Detected: ") + (NetworkInfo.primaryLANIPv4() ?? L.t("未找到局域网地址", "no LAN address")))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
            saveBar(targetMode: .builtIn)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 外部服务

    private var externalTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionHeader(L.t("外部服务（公网远程）", "External (remote)"),
                          subtitle: L.t("连接已部署在公网的信令服务器，跨网络远程使用。",
                                        "Connect to a signaling server on the public internet for remote use."))
            modeBadge(active: settings.mode == .external)

            VStack(alignment: .leading, spacing: 12) {
                field(L.t("信令地址", "Address"), text: $externalURL, placeholder: "ws://example.com:8080")
                Text(L.t("二维码将广播此地址，供手机连接。",
                         "The QR code broadcasts this address for the phone to connect."))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Spacer()
            saveBar(targetMode: .external)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 日志

    private var logTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(L.t("运行日志", "Logs")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(L.t("清空", "Clear")) { state.logLines.removeAll() }
                    .controlSize(.small)
            }
            ScrollView {
                Text(state.logLines.isEmpty ? L.t("暂无日志", "No logs yet") : state.logLines.joined(separator: "\n"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(state.logLines.isEmpty ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxHeight: .infinity)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(6)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 复用组件

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 14, weight: .bold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 当前模式标识：每个 Tab 表明它是否为当前生效模式。
    private func modeBadge(active: Bool) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 7, height: 7)
            Text(active ? L.t("当前生效模式", "Active mode") : L.t("未启用（保存后切换到此模式）", "Inactive (save to switch here)"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private func saveBar(targetMode: SignalingMode) -> some View {
        HStack {
            Spacer()
            Button(L.t("保存并应用", "Save & Apply")) { save(mode: targetMode) }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func field(_ label: String, text: Binding<String>, placeholder: String = "") -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.system(size: 12))
                .frame(width: 76, alignment: .leading)
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func save(mode: SignalingMode) {
        if let port = Int(listenPort.filter(\.isNumber)), port > 0, port <= 65535 {
            settings.listenPort = port
        }
        settings.ipOverride = ipOverride.trimmingCharacters(in: .whitespaces)
        settings.externalURL = Self.normalizeExternalURL(externalURL)
        // 外部模式地址为空时自动回退到内置服务。
        if mode == .external && settings.externalURL.isEmpty {
            settings.mode = .builtIn
        } else {
            settings.mode = mode
        }
        settings.apply()
        onClose()
    }

    /// 规范化外部地址：补全缺失的 ws:// 前缀；https/http 映射为 wss/ws。
    static func normalizeExternalURL(_ raw: String) -> String {
        AppSettings.normalizeExternalURL(raw)
    }
}
