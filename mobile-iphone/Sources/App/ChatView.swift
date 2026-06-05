import SwiftUI
import UIKit

private enum TalkUX {
    static let cursorActivation: CGFloat = 28
    static let cursorStep: CGFloat = 24
    static let swipeTrigger: CGFloat = 32
    static let verticalBias: CGFloat = 1.8
    static let continuousThreshold: CGFloat = 96
    static let sideButtonHalf: CGFloat = 28
    static let repeatSlow: Double = 0.2
    static let repeatFast: Double = 0.04
    static let tapMaxDuration: Double = 0.18
    static let doubleTapMax: Double = 0.35
    static let composerLift: CGFloat = 56
    static let holdDuration: Double = 0.75
}

// 单链骨架：VStack { header / messages / inputView }。
// 本步：接入真实 voice / text 输入区（messages、header 仍为占位，后续替换）。
struct ChatView: View {
    @EnvironmentObject private var connections: ConnectionManager
    @Environment(\.dismiss) private var dismiss
    let connectionId: String
    let sessionId: String

    private enum InputMode {
        case voice
        case text
    }

    @StateObject private var speech = SpeechRecognizer()
    @State private var hint = "按住说话"
    @State private var inputMode: InputMode = .voice
    @State private var inputText = ""
    @State private var inputFocused = false
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
    @State private var cursorContinuousThreshold: CGFloat = TalkUX.continuousThreshold
    @State private var cursorAbsDelta: CGFloat = 0
    @State private var isContinuous = false
    @State private var pullProgress: CGFloat = 0

    private var session: DesktopSession? { connections.session(connectionId: connectionId, sessionId: sessionId) }

    var body: some View {
        ZStack(alignment: .top) {
            AppColor.bg.ignoresSafeArea()

            if session == nil {
                Text("桌面窗口已关闭")
                    .font(.system(size: 15))
                    .foregroundStyle(AppColor.textSecondary)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { dismiss() }
                    }
            }

            if session != nil {
                VStack(spacing: 0) {
                    header
                    messages
                    inputView
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("更多操作", isPresented: $showHeaderActions, titleVisibility: .hidden) {
            Button("全选") { sendAction("selectAll") }
            Button("清空") { sendAction("clear"); showToast("已清空") }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: inputMode) { mode in
            inputFocused = mode == .text
        }
        .onChange(of: connections.isConnected) { connected in
            if !connected {
                showToast("桌面已断开")
                dismiss()
            }
        }
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
                if message.contains("模拟器") { inputMode = .text; inputFocused = true }
            }
        }
        .onDisappear { speech.teardown() }
    }

    // MARK: header
    private var header: some View {
        let title = session?.displayApp ?? "未知应用"
        let caption = session?.displayTitle ?? "当前窗口"
        return HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColor.textSecondary)
                    .frame(width: 40, height: 40)
                    .background(AppColor.surfaceAlt)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(AppColor.textPrimary)
                        .lineLimit(1)
                    Text(caption)
                        .font(.system(size: 13))
                        .foregroundStyle(AppColor.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }
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
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    // MARK: messages（真实消息列表，唯一弹性区）
    private var messages: some View {
        let liveSession = session
        let list = displayedMessages
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .trailing, spacing: 10) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .contextMenu {
                                if let liveSession, !liveSession.messages.isEmpty {
                                    Button("重新发送") {
                                        connections.resendText(session: liveSession, text: message.text)
                                        showToast("已发送")
                                    }
                                    Button("删除", role: .destructive) {
                                        connections.deleteMessage(session: liveSession, at: index)
                                    }
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 12)
            }
            .onAppear {
                if let last = list.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: list.count) { _ in
                if let last = list.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 真实会话消息；无会话或为空时不再注入演示数据。
    private var displayedMessages: [ChatMessage] {
        session?.messages ?? []
    }

    // MARK: inputView（固定高度，voice / text 切换）
    @ViewBuilder
    private var inputView: some View {
        ZStack(alignment: .bottom) {
            if let session {
                switch inputMode {
                case .voice:
                    voiceInputView(session)
                        .padding(.bottom, -13)
                case .text:
                    textInputView(session)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(AppColor.bg)
    }

    // MARK: - voice input view（真实语音面板）
    private func voiceInputView(_ session: DesktopSession) -> some View {
        VStack(spacing: 8) {
            Text(hint)
                .font(.system(size: 13))
                .foregroundStyle(AppColor.textTertiary)
                .opacity(Double(1 - pullProgress))
            composerBody(session)
                // 误触保护：仅面板四周窄带触发上划，中间麦克风/侧按钮区不抢手势。
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
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .offset(y: -TalkUX.composerLift * pullProgress)
    }

    /// 上划弹出文本输入：上拉超过阈值切到文本模式并拉起键盘。
    private func pullGesture() -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                let pulled = max(0, -value.translation.height)
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.85)) {
                    pullProgress = min(1, pulled / TalkUX.composerLift)
                }
            }
            .onEnded { value in
                let pulled = max(0, -value.translation.height)
                if pulled > TalkUX.composerLift * 0.55 {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    inputMode = .text
                    inputFocused = true
                    pullProgress = 0
                } else {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        pullProgress = 0
                    }
                }
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
        .padding(.vertical, 3)
        .background(
            GeometryReader { proxy in
                Color.clear.onAppear {
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

    private var directionHints: some View {
        let vR: CGFloat = 49
        let dotNear: CGFloat = 44
        let dotFar: CGFloat = 51
        let chevronGap: CGFloat = 9
        let hR: CGFloat = (isContinuous ? dotFar : dotNear) + chevronGap
        let tint = AppColor.accent.opacity(0.34)
        let horizontalActive = inCursorMode && !cursorVertical
        let verticalActive = inCursorMode && cursorVertical
        return ZStack {
            Image(systemName: "chevron.compact.up").offset(y: -vR).opacity(horizontalActive ? 0 : 1)
            Image(systemName: "chevron.compact.down").offset(y: vR).opacity(horizontalActive ? 0 : 1)
            Image(systemName: "chevron.compact.left").offset(x: -hR).opacity(verticalActive ? 0 : 1)
            Image(systemName: "chevron.compact.right").offset(x: hR).opacity(verticalActive ? 0 : 1)
            Circle().frame(width: 3, height: 3).offset(x: -dotNear).opacity(verticalActive ? 0 : 1)
            Circle().frame(width: 3, height: 3).offset(x: dotNear).opacity(verticalActive ? 0 : 1)
            Circle().frame(width: 3, height: 3).offset(x: -dotFar).opacity(isContinuous && !verticalActive ? 1 : 0)
            Circle().frame(width: 3, height: 3).offset(x: dotFar).opacity(isContinuous && !verticalActive ? 1 : 0)
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
                .background(Circle().fill(AppColor.accent))
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
                .onEnded { value in handleTalkDragEnded(value) }
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
            hint = abs(d) >= TalkUX.swipeTrigger ? (d > 0 ? "↓ 松手切到下一行" : "↑ 松手切到上一行") : "↑ 上滑松手切行 ↓"
        } else {
            let d = value.translation.width - cursorBaseline.width
            cursorDelta = d
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
        for _ in 0..<count { sendCursor(positive ? "cursorRight" : "cursorLeft") }
        lastStepIndex = stepIndex
    }

    private func updateRepeat(absDelta: CGFloat) {
        if absDelta >= cursorContinuousThreshold {
            if repeatTimer == nil { scheduleNextRepeat() }
            if !isContinuous { withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { isContinuous = true } }
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
                    stopRepeat(); return
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
        if isContinuous { withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { isContinuous = false } }
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
                speech.cancel(); isTalking = false; handleQuickTap()
            } else {
                speech.stop(); isTalking = false; hint = idleHint()
            }
        }
        talkGestureActive = false
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

    // MARK: - text input view（真实文本输入）
    private func textInputView(_ session: DesktopSession) -> some View {
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                inputFocused = false
                withAnimation { inputMode = .voice }
            } label: {
                Image(systemName: "mic.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(AppColor.accent)
                    .frame(width: 40, height: 40)
                    .background(AppColor.surfaceAlt)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            UIKitInputField(
                text: $inputText,
                isFirstResponder: $inputFocused,
                onSubmit: { sendTypedText(session) }
            )
                .frame(minHeight: 24, alignment: .topLeading)
                .overlay(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("输入文字…")
                            .font(.system(size: 16))
                            .foregroundStyle(AppColor.textTertiary)
                            .padding(.top, 1)
                            .allowsHitTesting(false)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(AppColor.surfaceAlt)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
        .frame(maxWidth: .infinity)
        .background(AppColor.surface)
        .overlay(Rectangle().fill(AppColor.line).frame(height: 1), alignment: .top)
        .gesture(DragGesture(minimumDistance: 18).onEnded { value in
            if value.translation.height > 28 {
                inputFocused = false
                withAnimation { inputMode = .voice }
            }
        })
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
            .frame(maxWidth: 280, alignment: message.fromMe ? .trailing : .leading)
            .frame(maxWidth: .infinity, alignment: message.fromMe ? .trailing : .leading)
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

private struct UIKitInputField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFirstResponder: Bool
    var onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(frame: .zero)
        view.backgroundColor = .clear
        view.font = .systemFont(ofSize: 16)
        view.textColor = UIColor.label
        view.autocorrectionType = .yes
        view.autocapitalizationType = .sentences
        view.returnKeyType = .default
        view.isScrollEnabled = false
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text { uiView.text = text }
        if isFirstResponder {
            if !uiView.isFirstResponder { uiView.becomeFirstResponder() }
        } else if uiView.isFirstResponder {
            uiView.resignFirstResponder()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        let width = proposal.width ?? uiView.bounds.width
        guard width > 0 else { return CGSize(width: 0, height: 24) }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: max(24, size.height))
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFirstResponder: $isFirstResponder, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private var text: Binding<String>
        private var isFirstResponder: Binding<Bool>
        private let onSubmit: () -> Void

        init(text: Binding<String>, isFirstResponder: Binding<Bool>, onSubmit: @escaping () -> Void) {
            self.text = text
            self.isFirstResponder = isFirstResponder
            self.onSubmit = onSubmit
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            isFirstResponder.wrappedValue = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            isFirstResponder.wrappedValue = false
        }
    }
}

private struct HoldProgressButton: View {
    let systemName: String
    let onTap: () -> Void
    let onHold: () -> Void
    var size: CGFloat = 56
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
