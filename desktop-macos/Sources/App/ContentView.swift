import SwiftUI
import AppKit

/// 菜单栏下拉面板：仅做信息展示与最核心操作（启停 / 设置 / 退出）。
/// 详细配置在独立的设置窗口里完成，保持面板简洁。
struct ContentView: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var settings = AppSettings.shared
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            qrSection
            if !state.accessibilityGranted { accessibilityNotice }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
    }

    // MARK: - 顶部状态

    private var header: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(state.connected ? Color.green : (state.serviceActive ? Color.orange : Color.gray))
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.t("ChatPUT", "ChatPUT")).font(.system(size: 13, weight: .bold))
                Text(state.connected && !state.connectedDevice.isEmpty
                     ? L.t("已连接：", "Connected: ") + state.connectedDevice
                     : state.statusText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 二维码

    private var qrSection: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white)
                    .frame(width: 220, height: 220)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 1)
                if let img = state.qrImage {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: state.serviceActive ? "qrcode" : "pause.circle")
                            .font(.system(size: 30))
                            .foregroundColor(.secondary)
                        Text(state.serviceActive ? L.t("等待二维码…", "Waiting for QR code…") : L.t("服务已停止", "Service stopped"))
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                }
            }

            if !state.advertisedURL.isEmpty {
                Text(state.advertisedURL)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(L.t("手机扫码即可配对", "Scan with your phone to pair"))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    private var accessibilityNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
                .font(.system(size: 11))
            Text(L.t("需在「系统设置 → 隐私与安全性 → 辅助功能」勾选本应用，否则无法注入文字。",
                     "Enable this app in System Settings → Privacy & Security → Accessibility, otherwise text cannot be injected."))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - 底部操作

    private var footer: some View {
        HStack(spacing: 10) {
            Button {
                if state.serviceActive {
                    Coordinator.shared.stopService()
                } else {
                    Coordinator.shared.startService()
                }
            } label: {
                Label(state.serviceActive ? L.t("停止", "Stop") : L.t("启动", "Start"),
                      systemImage: state.serviceActive ? "stop.fill" : "play.fill")
            }

            Spacer()

            Button { onOpenSettings() } label: {
                Image(systemName: "gearshape")
            }
            .help(L.t("设置", "Settings"))

            Button { NSApp.terminate(nil) } label: {
                Image(systemName: "power")
            }
            .help(L.t("退出", "Quit"))
        }
        .controlSize(.regular)
    }
}

