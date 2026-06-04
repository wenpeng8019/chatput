import SwiftUI

struct MainView: View {
    @EnvironmentObject private var connections: ConnectionManager
    @State private var scannerVisible = false
    @State private var toast: String?
    @State private var showConnections = false
    @Namespace private var headerNS

    // 与 Android 对齐：会话列表反向贴底，标题区在内容多时随滚动自然推出。
    private let headerTopPad: CGFloat = 14   // header 距屏幕顶
    private let itemGap: CGFloat = 10        // 项间距 & 标题↔首项间距（统一）
    private let listBottomInset: CGFloat = 110 // 列表底部为扫码按钮预留（Android 110dp）

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppColor.bg.ignoresSafeArea()

                // 反向会话列表：header 在顶、会话贴底向上延展；内容多时 header 随滚动被推出（对齐 Android）。
                sessionScroll

                // 底部固定层：历史连接 + 空态 + 扫码按钮（对齐 Android 底部约束链）。
                VStack(spacing: 0) {
                    recentArea
                    emptyHint
                    scanButton
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 24)

                if let toast {
                    Text(toast)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .background(AppColor.statusIdleBg)
                        .clipShape(Capsule())
                        .padding(.bottom, 104)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .navigationBarHidden(true)
            .sheet(isPresented: $scannerVisible) {
                QRScannerView { code in
                    scannerVisible = false
                    pair(code, fromRecent: false)
                } onCancel: {
                    scannerVisible = false
                }
                .ignoresSafeArea()
            }
            .confirmationDialog(connections.connectionGroupLabel(), isPresented: $showConnections, titleVisibility: .visible) {
                ForEach(connections.connectedDesktops()) { desktop in
                    Button("关闭 \(desktop.label)", role: .destructive) {
                        connections.disconnect(desktop.id)
                        showToast("已断开 \(desktop.label)")
                    }
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: connections.hasConnectionContext ? 0 : 8) {
            if connections.hasConnectionContext {
                HStack(spacing: 12) {
                    Text("ChatPUT")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(AppColor.accent)
                    Spacer(minLength: 8)
                    statusChip
                        .matchedGeometryEffect(id: "statusChip", in: headerNS)
                }
                .transition(.opacity)
            } else {
                Text("ChatPUT")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(AppColor.accent)
                Text("把桌面输入做得更自然")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(AppColor.textPrimary)
                    .padding(.top, 2)
                Text("连接后，当前聚焦窗口会自动成为会话。")
                    .font(.system(size: 14))
                    .foregroundStyle(AppColor.textSecondary)
                statusChip
                    .matchedGeometryEffect(id: "statusChip", in: headerNS)
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 16)
        .padding(.trailing, connections.hasConnectionContext ? 16 : 18)
        .padding(.vertical, connections.hasConnectionContext ? 14 : 18)
        .panel()
        // 大标题区 ↔ 紧凑标题区转场：对标 Android ChangeBounds + Fade（260ms 减速曲线）。
        .animation(.easeOut(duration: 0.26), value: connections.hasConnectionContext)
    }

    private var statusChip: some View {
        Button {
            if connections.isConnected { showConnections = true }
        } label: {
            Text(connections.status)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(connections.isConnected ? AppColor.statusConnectedText : AppColor.statusIdleText)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(connections.isConnected ? AppColor.statusConnectedBg : AppColor.statusIdleBg)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!connections.isConnected)
    }

    private var sessionScroll: some View {
        GeometryReader { geo in
            // 180° 旋转翻转技巧：ScrollView 旋转后「顶部吸附」变「底部吸附」，
            // 焦点会话天然贴底、溢出时自动可见，无需 scrollTo，杜绝抖动（对齐 Android reverseLayout）。
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    // 会话块：项间距与「标题↔首项」间距统一为 itemGap。
                    VStack(spacing: itemGap) {
                        // 数据序：焦点 sessions[0] 在最前 → 旋转后位于视觉底部，向上延展。
                        ForEach(connections.sessions) { session in
                            NavigationLink(value: session.id) {
                                SessionRow(session: session)
                            }
                            .buttonStyle(.plain)
                            .rotationEffect(.degrees(180))
                            // 增删动效：缩放+淡入淡出（与旋转无关，避免方向混乱）。
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    // 增删/焦点重排时，列表布局做弹性动画。
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: connections.sessions.map(\.id))

                    // 可伸缩间隔：项少时撑开，把列表压到视觉底部、标题顶到视觉顶部；项多时收为 0。
                    Spacer(minLength: 0)

                    // 标题区为数据最后一项 → 旋转后位于视觉顶部。
                    // padding.top → 视觉顶部留白（距屏幕顶）；padding.bottom → 视觉底部（与首项间隔 = itemGap）。
                    header
                        .padding(.top, headerTopPad)
                        .padding(.bottom, itemGap)
                        .rotationEffect(.degrees(180))
                }
                .padding(.horizontal, 18)
                .padding(.top, listBottomInset)   // 旋转后 → 视觉底部留白（扫码按钮区）
                .frame(minHeight: geo.size.height, alignment: .top)
            }
            .rotationEffect(.degrees(180))
            .navigationDestination(for: String.self) { compositeId in
                let parts = compositeId.split(separator: "#", maxSplits: 1).map(String.init)
                ChatView(connectionId: parts.first ?? "", sessionId: parts.dropFirst().first ?? "")
            }
        }
    }

    private var recentArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !connections.hasConnectionContext {
                let pairings = connections.recentPairings()
                if !pairings.isEmpty {
                    Text("历史连接")
                        .font(.system(size: 13))
                        .foregroundStyle(AppColor.textTertiary)
                        .padding(.leading, 2)
                    VStack(spacing: 8) {
                        ForEach(pairings) { pairing in
                            RecentRow(
                                pairing: pairing,
                                isReconnecting: connections.isConnecting(connectionId: pairing.id),
                                reconnect: { pair(pairing.payload) },
                                delete: { connections.removeRecent(payload: pairing.payload) }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 36)
        .padding(.bottom, 24)
    }

    private var emptyHint: some View {
        Text(emptyText)
            .font(.system(size: 15))
            .foregroundStyle(AppColor.textSecondary)
            .padding(.horizontal, 22)
            .padding(.vertical, 13)
            .background(AppColor.statusIdleBg)
            .clipShape(Capsule())
            .padding(.bottom, 16)
            .opacity(connections.sessions.isEmpty ? 1 : 0)
            .allowsHitTesting(false)
    }

    private var scanButton: some View {
        Button {
            scannerVisible = true
        } label: {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(AppColor.accent)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var emptyText: String {
        if connections.hasConnectionContext { return "已连接，请先在桌面选择要输入的窗口" }
        if connections.isConnecting { return "正在连接桌面…" }
        return "扫码连接你的桌面"
    }

    private func pair(_ raw: String, fromRecent: Bool) {
        do {
            try connections.pair(rawPayload: raw)
            showToast("配对中…")
        } catch {
            showToast("二维码无效")
        }
    }

    private func pair(_ payload: QRPairingPayload) {
        connections.pair(payload)
        showToast("配对中…")
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { toast = nil } }
    }
}

private struct SessionRow: View {
    let session: DesktopSession

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(session.isActive ? AppColor.accent : Color.clear)
                .frame(width: 4, height: 34)
            VStack(alignment: .leading, spacing: 5) {
                Text(session.displayApp)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Text(session.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            if session.isActive {
                Circle().fill(AppColor.accent).frame(width: 9, height: 9)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(session.isActive ? AppColor.surfaceActive : AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(session.isActive ? AppColor.accentSoft : AppColor.line, lineWidth: 1))
    }
}

private struct RecentRow: View {
    let pairing: Pairing
    let isReconnecting: Bool
    let reconnect: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: delete) {
                Image(systemName: "trash")
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(width: 20, height: 20)
            }
            .opacity(isReconnecting ? 0 : 1)
            .disabled(isReconnecting)

            Text(pairing.label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppColor.textPrimary)
            Spacer()
            if isReconnecting {
                CircularSpinner()
            } else {
                Text("重新连接")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppColor.accent)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.vertical, 12)
        .background(AppColor.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(AppColor.line, lineWidth: 1))
        .onTapGesture { if !isReconnecting { reconnect() } }
    }
}

/// 与 Android Material 圆弧旋转进度一致：一段圆环弧线匀速旋转。
private struct CircularSpinner: View {
    var size: CGFloat = 18
    var lineWidth: CGFloat = 2.2
    @State private var rotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.75)
            .stroke(AppColor.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(rotating ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
            .onAppear { rotating = true }
    }
}
