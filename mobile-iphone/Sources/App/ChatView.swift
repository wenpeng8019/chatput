import SwiftUI
import UIKit

private enum TalkUX {
    static let cursorActivation: CGFloat = 28
    static let cursorStep: CGFloat = 24
    static let swipeTrigger: CGFloat = 32
    static let verticalBias: CGFloat = 1.8
    /// 连续移动阈值的回退默认值。运行时会根据面板实际宽度重算为「麦克风中心 → 侧按钮中心」的距离（见 ChatView.measuredContinuousThreshold）。
    static let continuousThreshold: CGFloat = 96
    /// 侧按钮（退格 / 回车）直径的一半，用于推算其中心位置。
    static let sideButtonHalf: CGFloat = 28
    static let repeatSlow: Double = 0.2
    static let repeatFast: Double = 0.04
    static let tapMaxDuration: Double = 0.18
    static let doubleTapMax: Double = 0.35
    static let composerLift: CGFloat = 56
    static let holdDuration: Double = 0.75
}

struct ChatView: View {
    @EnvironmentObject private var connections: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    let connectionId: String
    let sessionId: String

    @StateObject private var speech = SpeechRecognizer()
    @State private var hint = "按住说话"
    @State private var inputVisible = false
    @State private var inputText = ""
    @State private var toast: String?
    @State private var showHeaderActions = false
    @State private var talkMode = SpeechRecognizer.Mode.standard
    @State private var lastQuickTap = Date.distantPast
    @State private var isTalking = false
    @State private var talkStartedAt = Date.distantPast
    @State private var talkGestureActive = false

    @State private var inCursorMode = false
    @State private var cursorVertical = false
    @State private var cursorBaseline: CGSize = .zero
    @State private var cursorDelta: CGFloat = 0
    @State private var lastStepIndex: Int = 0
    @State private var repeatTimer: Timer?

    /// 连续光标移动的触发阈值：麦克风中心 → 侧按钮中心的水平距离，随面板实际宽度自适应。
    @State private var cursorContinuousThreshold: CGFloat = TalkUX.continuousThreshold
    /// 手指相对麦克风中心的水平偏移（点），作为连续触发的绝对基准（不随进入光标模式重定基线）。
    @State private var cursorAbsDelta: CGFloat = 0
    /// 是否处于连续触发态：方向提示的圆点由一个裂变为两个，反馈「已进入连续滑动」。
    @State private var isContinuous = false

    @State private var pullProgress: CGFloat = 0


    private var session: DesktopSession? { connections.session(connectionId: connectionId, sessionId: sessionId) }

    var body: some View {
        ZStack(alignment: .bottom) {
            AppColor.bg.ignoresSafeArea()
            if let session {
                VStack(spacing: 0) {
                    header(session)
                    messages(session)
                    Text(hint)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColor.textTertiary)
                        .padding(.bottom, 8)
                        .offset(y: -TalkUX.composerLift * pullProgress)
                        .opacity(inputVisible ? 0 : Double(1 - pullProgress))
                    if inputVisible {
                        textInput(session)
                    } else {
                        voiceComposer(session)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                // 下压进入底部安全区，使系统 Home 横杠中心(≈距底10.5pt)落在面板底边与屏幕底的视觉中点。
                // 间隙 = 34(安全区) − 13 = 21pt，中点 ≈ 10.5pt ≈ 横杠中心。
                .padding(.bottom, -13)
            } else {
                Text("桌面窗口已关闭")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textSecondary)
                    .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dismiss() } }
            }

            if let toast {
                Text(toast)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppColor.textSecondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(AppColor.statusIdleBg)
                    .clipShape(Capsule())
                    .padding(.bottom, 112)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            speech.requestPermissions()
            speech.prepare()
            speech.onPartial = { hint = $0 }
            speech.onResult = { text in
                isTalking = false
                hint = idleHint()
                if let session = self.session, !text.isEmpty { connections.sendText(session: session, text: text) }
            }
            speech.onError = { message in
                showToast(message)
                hint = idleHint()
                isTalking = false
                if message.contains("模拟器") { withAnimation { inputVisible = true } }
            }
        }
        .onChange(of: connections.isConnected) { connected in
            if !connected { showToast("桌面已断开"); dismiss() }
        }
        .onDisappear {
            speech.teardown()
        }
        .confirmationDialog("更多操作", isPresented: $showHeaderActions, titleVisibility: .hidden) {
            Button("全选") { sendAction("selectAll") }
            Button("清空") { sendAction("clear"); showToast("已清空") }
            Button("取消", role: .cancel) {}
        }
    }

    private func header(_ session: DesktopSession) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(session.displayApp)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(AppColor.textPrimary)
                    .lineLimit(1)
                Text(session.displayTitle)
                    .font(.system(size: 13))
                    .foregroundStyle(AppColor.textSecondary)
                    .lineLimit(1)
            }
            Spacer()
            Button { showHeaderActions = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(AppColor.surfaceAlt)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .panel()
    }

    private func messages(_ session: DesktopSession) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .trailing, spacing: 10) {
                    ForEach(Array(session.messages.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .contextMenu {
                                Button("重新发送") { connections.resendText(session: session, text: message.text); showToast("已发送") }
                                Button("删除", role: .destructive) { connections.deleteMessage(session: session, at: index) }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .onChange(of: session.messages.count) { _ in
                if let last = session.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    private func voiceComposer(_ session: DesktopSession) -> some View {
        // 可见面板（含按钮）随拖动上移淡出；按钮可点击。
        // .offset 不改变布局 frame，因此其后挂的热区 overlay 保持静止，不随拖动移动（避免手势取消弹跳）。
        composerBody(session)
            .offset(y: -TalkUX.composerLift * pullProgress)
            .opacity(Double(1 - pullProgress))
            .overlay(alignment: .top) {
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.black.opacity(0.0001))
                        .frame(maxWidth: .infinity)
                        .gesture(pullGesture())
                    Color.clear
                        .frame(width: 140)
                        .allowsHitTesting(false)
                    Rectangle()
                        .fill(Color.black.opacity(0.0001))
                        .frame(maxWidth: .infinity)
                        .gesture(pullGesture())
                }
                .frame(height: 28 + 10)
                .offset(y: -10)
            }
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color.black.opacity(0.0001))
                    .frame(width: 20 + 10)
                    .frame(maxHeight: .infinity)
                    .padding(.top, -10)
                    .offset(x: -10)
                    .gesture(pullGesture())
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.black.opacity(0.0001))
                    .frame(width: 20 + 10)
                    .frame(maxHeight: .infinity)
                    .padding(.top, -10)
                    .offset(x: 10)
                    .gesture(pullGesture())
            }
    }

    private func composerBody(_ session: DesktopSession) -> some View {
        HStack {
            HoldProgressButton(
                systemName: "delete.left",
                onTap: { sendAction("backspace") },
                onHold: { sendAction("clear"); showToast("已清空") }
            )
            Spacer()
            talkButton(session)
            Spacer()
            HoldProgressButton(
                systemName: "return",
                onTap: { sendAction("shiftEnter") },
                onHold: { sendAction("enter") }
            )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear {
                    // 面板内容宽 = 面板宽 - 2×20（水平内边距）；侧按钮贴靠内容边缘，
                    // 其中心距面板中心 = 内容宽/2 − 侧按钮半径。
                    let contentWidth = proxy.size.width - 40
                    cursorContinuousThreshold = max(TalkUX.cursorStep,
                                                    contentWidth / 2 - TalkUX.sideButtonHalf)
                }
            }
        )
        .panel(cornerRadius: 34)
        .overlay(alignment: .top) {
            HStack {
                CornerArc(mirrored: false)
                    .stroke(AppColor.textTertiary.opacity(0.28),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: 34, height: 34)
                Spacer()
                CornerArc(mirrored: true)
                    .stroke(AppColor.textTertiary.opacity(0.28),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .frame(width: 34, height: 34)
            }
            .allowsHitTesting(false)
        }
    }

    private func pullGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let pulled = max(0, -value.translation.height)
                pullProgress = min(1, pulled / TalkUX.composerLift)
            }
            .onEnded { value in
                let pulled = max(0, -value.translation.height)
                if pulled > TalkUX.composerLift * 0.55 {
                    withAnimation(.easeOut(duration: 0.18)) {
                        inputVisible = true
                        pullProgress = 0
                    }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        pullProgress = 0
                    }
                }
            }
    }

    /// 中间麦克风按钮四周的四向 chevron 提示，暗示可向四方拖拽。
    /// 左右↔移光标（内侧加小点，暗示可连续拖动），上下↔切行；仅空闲态显示，说话/光标模式时淡出让位。
    private var directionHints: some View {
        // 上下：与中心距离固定（vR=49），不动。
        // 左右：留白多，chevron 不与上下对齐，而是紧挨最外侧的点。
        //   空闲 → 一个点 + 紧贴箭头；连续触发 → 第二点淡入，箭头随之外移一格让位。
        let vR: CGFloat = 49
        let dotNear: CGFloat = 44   // 常驻点
        let dotFar: CGFloat = 51    // 连续态淡入的第二点
        let chevronGap: CGFloat = 9 // 箭头与最外侧点的间距
        let hR: CGFloat = (isContinuous ? dotFar : dotNear) + chevronGap
        let tint = AppColor.accent.opacity(0.34)
        // 光标模式下按方向聚焦：水平移动隐藏上下，垂直切行隐藏左右；空闲态全显。
        let horizontalActive = inCursorMode && !cursorVertical
        let verticalActive = inCursorMode && cursorVertical
        return ZStack {
            // 上下 chevron：水平移动时隐藏。
            Image(systemName: "chevron.compact.up").offset(y: -vR)
                .opacity(horizontalActive ? 0 : 1)
            Image(systemName: "chevron.compact.down").offset(y: vR)
                .opacity(horizontalActive ? 0 : 1)
            // 左右 chevron：垂直切行时隐藏。
            Image(systemName: "chevron.compact.left").offset(x: -hR)
                .opacity(verticalActive ? 0 : 1)
            Image(systemName: "chevron.compact.right").offset(x: hR)
                .opacity(verticalActive ? 0 : 1)
            // 常驻点
            Circle().frame(width: 3, height: 3).offset(x: -dotNear)
                .opacity(verticalActive ? 0 : 1)
            Circle().frame(width: 3, height: 3).offset(x: dotNear)
                .opacity(verticalActive ? 0 : 1)
            // 连续态第二点（淡入/淡出）
            Circle().frame(width: 3, height: 3).offset(x: -dotFar)
                .opacity(isContinuous && !verticalActive ? 1 : 0)
            Circle().frame(width: 3, height: 3).offset(x: dotFar)
                .opacity(isContinuous && !verticalActive ? 1 : 0)
        }
        .font(.system(size: 15, weight: .regular))
        .foregroundStyle(tint)
        .frame(width: 130, height: 110)
        .opacity(isTalking ? 0 : 1)
        .allowsHitTesting(false)
    }

    private func talkButton(_ session: DesktopSession) -> some View {
        ZStack {
            Circle()
                .fill(AppColor.accent.opacity(0.18))
                .frame(width: 110, height: 110)
                .scaleEffect(isTalking ? 1.0 : 0.7)
                .opacity(isTalking ? 1 : 0)
            directionHints
            Image(systemName: "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 78, height: 78)
                .background(
                    Circle()
                        .fill(AppColor.accent)
                )
                .shadow(color: AppColor.accent.opacity(isTalking ? 0.28 : 0.18), radius: 14, y: 4)
                .scaleEffect(isTalking ? 0.94 : 1.0)
        }
        .frame(width: 110, height: 110)
        .animation(.easeOut(duration: 0.15), value: isTalking)
        .animation(.easeOut(duration: 0.15), value: inCursorMode)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !talkGestureActive { talkBegan() }
                    handleTalkDragChanged(value)
                }
                .onEnded { value in
                    handleTalkDragEnded(value)
                }
        )
    }

    private func talkBegan() {
        guard session != nil else { return }
        talkGestureActive = true
        talkStartedAt = Date()
        inCursorMode = false
        cursorDelta = 0
        cursorBaseline = .zero
        lastStepIndex = 0
        startTalking()
    }

    private func handleTalkDragChanged(_ value: DragGesture.Value) {
        if !inCursorMode {
            let dist = hypot(value.translation.width, value.translation.height)
            if dist > TalkUX.cursorActivation {
                cursorVertical = abs(value.translation.height) > abs(value.translation.width) * TalkUX.verticalBias
                inCursorMode = true
                cursorBaseline = value.translation
                cursorDelta = 0
                lastStepIndex = 0
                speech.cancel()
                isTalking = false
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
                hint = cursorVertical ? "↑ 上滑松手切行 ↓" : "← 拖动移动光标 →"
            }
        }
        guard inCursorMode else { return }
        if cursorVertical {
            let d = value.translation.height - cursorBaseline.height
            cursorDelta = d
            if abs(d) >= TalkUX.swipeTrigger {
                hint = d > 0 ? "↓ 松手切到下一行" : "↑ 松手切到上一行"
            } else {
                hint = "↑ 上滑松手切行 ↓"
            }
        } else {
            let d = value.translation.width - cursorBaseline.width
            cursorDelta = d
            // 连续触发以麦克风中心为绝对基准（talkButton 手势帧 110×110，中心 x=55），
            // 与棘轮逐字的重定基线解耦，确保「滑到侧按钮中心」才切连续。
            cursorAbsDelta = value.location.x - 55
            updateRatchet(d)
            updateRepeat(absDelta: abs(cursorAbsDelta))
        }
    }

    private func updateRatchet(_ delta: CGFloat) {
        let stepIndex = Int((delta / TalkUX.cursorStep).rounded())
        guard stepIndex != lastStepIndex else { return }
        let positive = stepIndex > lastStepIndex
        let count = abs(stepIndex - lastStepIndex)
        for _ in 0..<count {
            sendCursor(positive ? "cursorRight" : "cursorLeft")
        }
        lastStepIndex = stepIndex
    }

    private func updateRepeat(absDelta: CGFloat) {
        if absDelta >= cursorContinuousThreshold {
            if repeatTimer == nil { scheduleNextRepeat() }
            if !isContinuous {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { isContinuous = true }
            }
        } else {
            stopRepeat()
        }
    }

    private func scheduleNextRepeat() {
        let interval = repeatInterval()
        repeatTimer?.invalidate()
        repeatTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            DispatchQueue.main.async {
                guard inCursorMode, !cursorVertical, abs(cursorAbsDelta) >= cursorContinuousThreshold else {
                    stopRepeat()
                    return
                }
                sendCursor(cursorAbsDelta > 0 ? "cursorRight" : "cursorLeft")
                scheduleNextRepeat()
            }
        }
    }

    private func repeatInterval() -> Double {
        let travel = abs(cursorAbsDelta)
        let start = cursorContinuousThreshold
        let full = start + TalkUX.cursorStep * 8
        let t = min(1, max(0, Double((travel - start) / (full - start))))
        return TalkUX.repeatSlow - (TalkUX.repeatSlow - TalkUX.repeatFast) * t
    }

    private func stopRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        if isContinuous {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { isContinuous = false }
        }
    }

    private func sendCursor(_ action: String) {
        guard let session else { return }
        connections.sendAction(session: session, action: action)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func handleTalkDragEnded(_ value: DragGesture.Value) {
        stopRepeat()
        if inCursorMode {
            if cursorVertical && abs(cursorDelta) >= TalkUX.swipeTrigger {
                let action = cursorDelta > 0 ? "cursorDown" : "cursorUp"
                if let session { connections.sendAction(session: session, action: action) }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }
            inCursorMode = false
            cursorDelta = 0
            hint = idleHint()
            isTalking = false
        } else {
            let held = Date().timeIntervalSince(talkStartedAt)
            if held < TalkUX.tapMaxDuration {
                speech.cancel()
                isTalking = false
                handleQuickTap()
            } else {
                speech.stop()
                isTalking = false
                hint = idleHint()
            }
        }
        talkGestureActive = false
    }

    private func textInput(_ session: DesktopSession) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("输入文字…", text: $inputText, axis: .vertical)
                .lineLimit(1...4)
                .font(.system(size: 16))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppColor.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onSubmit { sendTypedText(session) }
            Button { sendTypedText(session) } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(AppColor.accent)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(AppColor.surface)
        .overlay(Rectangle().fill(AppColor.line).frame(height: 1), alignment: .top)
        .gesture(DragGesture(minimumDistance: 18).onEnded { value in
            if value.translation.height > 28 { withAnimation { inputVisible = false } }
        })
    }

    private func actionButton(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 23, weight: .semibold))
                .foregroundStyle(AppColor.textSecondary)
                .frame(width: size, height: size)
                .background(AppColor.surfaceAlt)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func startTalking() {
        guard session != nil, !isTalking else { return }
        isTalking = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        hint = talkMode == .english ? "请说英文" : "正在听…"
        let mode = talkMode
        talkMode = .standard
        speech.start(mode: mode)
    }

    private func stopTalking() {
        guard isTalking else { return }
        isTalking = false
        speech.stop()
        hint = idleHint()
    }

    private func handleQuickTap() {
        let now = Date()
        if now.timeIntervalSince(lastQuickTap) < TalkUX.doubleTapMax, SpeechRecognizer.englishModeAvailable {
            talkMode = .english
            hint = "请说英文"
            lastQuickTap = .distantPast
        } else {
            lastQuickTap = now
            showToast("再按一次进入英文输入")
            hint = idleHint()
        }
    }

    private func idleHint() -> String {
        talkMode == .english ? "请说英文" : "按住说话"
    }

    private func sendTypedText(_ session: DesktopSession) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        connections.sendText(session: session, text: text)
        inputText = ""
    }

    private func sendAction(_ action: String) {
        guard let session else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        connections.sendAction(session: session, action: action)
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { toast = nil } }
    }
}

/// 面板顶部圆角同心弧线，半径等于面板 cornerRadius，曲率与面板边缘完全一致。
private struct CornerArc: Shape {
    var mirrored: Bool = false
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let r = rect.width
        let center = CGPoint(x: mirrored ? 0 : rect.width, y: rect.height)
        let start = Angle.degrees(mirrored ? 270 : 180)
        let end = Angle.degrees(mirrored ? 360 : 270)
        path.addArc(center: center, radius: r, startAngle: start, endAngle: end, clockwise: false)
        return path
    }
}

private struct MessageBubble: View {
    let message: ChatMessage

    var body: some View {
        Text(message.text)
            .font(.system(size: 16))
            .foregroundStyle(AppColor.textPrimary)
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
            .background(message.fromMe ? AppColor.messageBubble : AppColor.surface)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .frame(maxWidth: 280, alignment: .trailing)
    }
}

private struct HoldProgressButton: View {
    let systemName: String
    let onTap: () -> Void
    let onHold: () -> Void
    var size: CGFloat = 56
    /// 进度环直径：对齐中间大按钮（78），而非按钮自身，与 Android（control_primary）一致。
    var ringSize: CGFloat = 78
    var holdDuration: Double = TalkUX.holdDuration

    @State private var progress: CGFloat = 0
    @State private var pressed = false
    @State private var inGesture = false
    @State private var holdCompleted = false
    @State private var holdWorkItem: DispatchWorkItem?

    var body: some View {
        ZStack {
            Circle().fill(AppColor.surfaceAlt)
            Image(systemName: systemName)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(AppColor.textSecondary)
        }
        .frame(width: size, height: size)
        .overlay {
            // 旋转进度环：半径与中间大按钮一致（直径 ringSize），溢出按钮本体居中绘制。
            Circle()
                .trim(from: 0, to: progress)
                .stroke(AppColor.accent, style: StrokeStyle(lineWidth: ringSize / 20, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: ringSize, height: ringSize)
        }
        .scaleEffect(pressed ? 0.94 : 1.0)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !inGesture { begin() } }
                .onEnded { value in
                    let traveled = hypot(value.translation.width, value.translation.height)
                    end(cancelled: traveled > size * 0.7)
                }
        )
    }

    private func begin() {
        inGesture = true
        pressed = true
        holdCompleted = false
        progress = 0
        withAnimation(.linear(duration: holdDuration)) { progress = 1.0 }
        let work = DispatchWorkItem {
            guard pressed, !holdCompleted else { return }
            holdCompleted = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onHold()
        }
        holdWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration, execute: work)
    }

    private func end(cancelled: Bool) {
        let wasCompleted = holdCompleted
        pressed = false
        inGesture = false
        holdWorkItem?.cancel()
        holdWorkItem = nil
        if !wasCompleted && !cancelled {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onTap()
        }
        withAnimation(.easeOut(duration: 0.18)) { progress = 0 }
    }
}
