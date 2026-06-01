import SwiftUI

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            // 状态条
            HStack(spacing: 8) {
                Circle()
                    .fill(state.connected ? Color.green : Color.orange)
                    .frame(width: 10, height: 10)
                Text(state.status)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                Spacer()
            }

            // 二维码
            Group {
                if let img = state.qrImage {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 220, height: 220)
                        .background(Color.white)
                        .cornerRadius(8)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.gray.opacity(0.1))
                        .frame(width: 220, height: 220)
                        .overlay(Text("等待二维码…").foregroundColor(.secondary))
                }
            }
            Text(state.roomCode)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)

            if !state.accessibilityGranted {
                Text("⚠️ 需在「系统设置 → 隐私与安全性 → 辅助功能」勾选本应用，否则无法注入文字 / 监控焦点。")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // 焦点会话 + 日志
            VStack(alignment: .leading, spacing: 6) {
                Text("最近焦点会话")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(state.sessions) { s in
                            Text("\(s.app) — \(s.title)")
                                .font(.system(size: 11))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 80)
            }

            DisclosureGroup("日志") {
                ScrollView {
                    Text(state.logLines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 100)
            }
            .font(.system(size: 11))
        }
        .padding(16)
    }
}
