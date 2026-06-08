import SwiftUI
import UIKit
import WebRTC

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
    @State private var screenPanelOpen = false
    @State private var screenPanelDragOffset: CGFloat = 0
    @State private var inputViewTop: CGFloat = 0
    @State private var keyboardAnimationDuration: Double = 0.25
    @State private var keyboardAnimationCurve: UIView.AnimationCurve = .easeInOut
    @AppStorage("debugHotZones") private var debugHotZones = false
    @State private var headerTapCount = 0
    @State private var headerTapReset: DispatchWorkItem?
    @StateObject private var screenState = ScreenState()
    @State private var videoAreaSize: CGSize = .zero

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

            if session != nil, screenPanelOpen || screenPanelDragOffset != 0 {
                screenPanelOverlay
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .onPreferenceChange(InputViewFrameKey.self) { rect in
            if inputViewTop == 0 {
                inputViewTop = rect.minY
            } else {
                withAnimation(keyboardFollowAnimation) {
                    inputViewTop = rect.minY
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("更多操作", isPresented: $showHeaderActions, titleVisibility: .hidden) {
            Button("查看屏幕") { openScreenPanel() }
            Button("撤销") { sendAction("undo") }
            Button("全选") { sendAction("selectAll") }
            Button("清空") { sendAction("clear"); showToast("已清空") }
            if debugHotZones {
                Button("隐藏热区（调试）") { debugHotZones = false }
            } else {
                Button("显示热区（调试）") { debugHotZones = true }
            }
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
        .onChange(of: videoAreaSize) { size in
            if screenPanelOpen, let session, size.width > 0, size.height > 0 {
                connections.sendViewport(session: session, x: 0, y: 0,
                                         w: Int(size.width), h: Int(size.height))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            updateKeyboardAnimation(from: note)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            updateKeyboardAnimation(from: note)
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
            .contentShape(Rectangle())
            .gesture(screenPanelOpenGesture())
            .onTapGesture {
                headerTapCount += 1
                headerTapReset?.cancel()
                if headerTapCount >= 5 {
                    headerTapCount = 0
                    showHeaderActions = true
                } else {
                    let work = DispatchWorkItem { headerTapCount = 0 }
                    headerTapReset = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
                }
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
            Text(isInputLost ? "↑↓←→ 移动光标" : hint)
                .font(.system(size: 13))
                .foregroundStyle(AppColor.textTertiary)
                .opacity(isInputLost ? 1 : Double(1 - pullProgress))
            composerBody(session)
                // 方向模式下不显示上拉热区
                .overlay(alignment: .top) {
                    if !isInputLost {
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
                }
                .overlay(alignment: .leading) {
                    if !isInputLost {
                        Rectangle()
                            .fill(Color.black.opacity(0.0001))
                            .frame(width: 20 + 10)
                            .frame(maxHeight: .infinity)
                            .padding(.top, -10)
                            .offset(x: -10)
                            .gesture(pullGesture())
                    }
                }
                .overlay(alignment: .trailing) {
                    if !isInputLost {
                        Rectangle()
                            .fill(Color.black.opacity(0.0001))
                            .frame(width: 20 + 10)
                            .frame(maxHeight: .infinity)
                            .padding(.top, -10)
                            .offset(x: 10)
                            .gesture(pullGesture())
                    }
                }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .offset(y: isInputLost ? 0 : -TalkUX.composerLift * pullProgress)
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: InputViewFrameKey.self,
                        value: proxy.frame(in: .global)
                    )
            }
        )
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

    private var composerCornerArcs: some View {
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

    private var isInputLost: Bool { session?.inputAvailable == false }

    @ViewBuilder
    private func composerBody(_ session: DesktopSession) -> some View {
        if isInputLost {
            dpadComposerBody(session)
        } else {
            voiceComposerBody(session)
        }
    }

    private func voiceComposerBody(_ session: DesktopSession) -> some View {
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
        .overlay(alignment: .top) { composerCornerArcs }
    }

    private func dpadComposerBody(_ session: DesktopSession) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button { sendDpadAction("escape") } label: {
                    Image(systemName: "escape")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                        .frame(width: 56, height: 56)
                        .background(AppColor.surfaceAlt)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                Spacer()
                dpadCenter(session)
                Spacer()
                Button { sendDpadAction("enter") } label: {
                    Image(systemName: "return")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppColor.textSecondary)
                        .frame(width: 56, height: 56)
                        .background(AppColor.surfaceAlt)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 3)
        }
        .panel(cornerRadius: 34)
    }

    @ViewBuilder
    private func dpadCenter(_ session: DesktopSession) -> some View {
        let r: CGFloat = 39
        ZStack {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 78, height: 78)
                .background(Circle().fill(AppColor.accent.opacity(0.1)))
                .shadow(color: AppColor.accent.opacity(0.18), radius: 14, y: 4)
            dpadHotZone(offsetX: 0, offsetY: -r, size: r, action: "cursorUp")
            dpadHotZone(offsetX: 0, offsetY: r, size: r, action: "cursorDown")
            dpadHotZone(offsetX: -r, offsetY: 0, size: r, action: "cursorLeft")
            dpadHotZone(offsetX: r, offsetY: 0, size: r, action: "cursorRight")
        }
        .frame(width: 110, height: 110)
    }

    private func dpadHotZone(offsetX: CGFloat, offsetY: CGFloat, size: CGFloat, action: String) -> some View {
        Rectangle()
            .fill(debugHotZones ? AppColor.accent.opacity(0.2) : Color.clear)
            .frame(width: size, height: size)
            .offset(x: offsetX, y: offsetY)
            .contentShape(Rectangle())
            .onTapGesture { sendDpadAction(action) }
            .overlay {
                if debugHotZones {
                    Rectangle().stroke(AppColor.accent, lineWidth: 1)
                }
            }
    }

    private func sendDpadAction(_ action: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        sendAction(action)
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
        .background(
            GeometryReader { proxy in
                Color.clear
                    .preference(
                        key: InputViewFrameKey.self,
                        value: proxy.frame(in: .global)
                    )
            }
        )
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

    private var keyboardFollowAnimation: Animation {
        switch keyboardAnimationCurve {
        case .easeInOut:
            return .easeInOut(duration: keyboardAnimationDuration)
        case .easeIn:
            return .easeIn(duration: keyboardAnimationDuration)
        case .easeOut:
            return .easeOut(duration: keyboardAnimationDuration)
        case .linear:
            return .linear(duration: keyboardAnimationDuration)
        @unknown default:
            return .easeInOut(duration: keyboardAnimationDuration)
        }
    }

    private func updateKeyboardAnimation(from note: Notification) {
        let userInfo = note.userInfo ?? [:]
        if let duration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double {
            keyboardAnimationDuration = duration
        }
        if let curveRaw = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int,
           let curve = UIView.AnimationCurve(rawValue: curveRaw) {
            keyboardAnimationCurve = curve
        }
    }

    private var screenPanelOverlay: some View {
        GeometryReader { geo in
            let topInset = geo.safeAreaInsets.top
            let screenHeight = UIScreen.main.bounds.height
            let fallbackBottom = screenHeight - (geo.safeAreaInsets.bottom + 48)
            let measuredBottomFromTop = inputViewTop > 0 ? inputViewTop : 0
            let measuredBottom = measuredBottomFromTop > 0
                ? measuredBottomFromTop
                : fallbackBottom
            let panelHeight = min(screenHeight, max(360, measuredBottom))
            let restingOffset = -panelHeight - 18
            let openOffset = min(0, screenPanelDragOffset)
            let closedOffset = max(restingOffset, restingOffset + screenPanelDragOffset)
            let yOffset = screenPanelOpen ? openOffset : closedOffset
            VStack(spacing: 0) {
                VStack(spacing: 0) {
                    ZStack {
                        AppColor.videoSurface

                        if screenState.videoTrack != nil {
                            VideoRendererView(track: $screenState.videoTrack)
                        } else {
                            VStack(spacing: 10) {
                                Spacer(minLength: topInset + 24)
                                Image(systemName: "display")
                                    .font(.system(size: 34, weight: .regular))
                                    .foregroundStyle(.white.opacity(0.32))
                                Text("等待画面…")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.5))
                                Spacer(minLength: 0)
                            }
                        }

                        VStack {
                            Capsule()
                                .fill(Color.white.opacity(0.5))
                                .frame(width: 40, height: 4)
                                .padding(.top, topInset + 6)
                            Spacer()
                            HStack {
                                Spacer()
                                MinimapView(
                                    thumbnail: screenState.thumbnail,
                                    winW: screenState.metaWinW,
                                    winH: screenState.metaWinH,
                                    vpX: screenState.metaX,
                                    vpY: screenState.metaY,
                                    vpW: screenState.metaW,
                                    vpH: screenState.metaH,
                                    onViewportMove: { newX, newY in
                                        guard let session else { return }
                                        let w = screenState.metaW > 0 ? screenState.metaW : Int(videoAreaSize.width)
                                        let h = screenState.metaH > 0 ? screenState.metaH : Int(videoAreaSize.height)
                                        connections.sendViewport(session: session, x: newX, y: newY, w: w, h: h)
                                    }
                                )
                                .frame(width: 150, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                                )
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 22)
                        }
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.onAppear {
                                videoAreaSize = proxy.size
                            }.onChange(of: proxy.size) { newSize in
                                videoAreaSize = newSize
                            }
                        }
                    )
                    .frame(height: panelHeight)
                    .frame(maxWidth: .infinity)

                    LinearGradient(
                        colors: [Color.black.opacity(0.22), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 18)
                }
                .offset(y: yOffset)
                .gesture(screenPanelOverlayGesture(restingOffset: restingOffset))
                .allowsHitTesting(screenPanelOpen)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .animation(.timingCurve(0, 0, 0.2, 1, duration: 0.28), value: screenPanelOpen)
            .animation(keyboardFollowAnimation, value: inputViewTop)
        }
    }

    private func screenPanelOpenGesture() -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !screenPanelOpen else { return }
                screenPanelDragOffset = max(0, value.translation.height)
            }
            .onEnded { value in
                guard !screenPanelOpen else {
                    screenPanelDragOffset = 0
                    return
                }
                defer { screenPanelDragOffset = 0 }
                if value.translation.height > 44 || value.predictedEndTranslation.height > 80 {
                    openScreenPanel()
                }
            }
    }

    private func screenPanelOverlayGesture(restingOffset: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if screenPanelOpen {
                    screenPanelDragOffset = min(0, value.translation.height)
                } else {
                    screenPanelDragOffset = max(restingOffset, value.translation.height)
                }
            }
            .onEnded { value in
                let drag = value.translation.height
                let predicted = value.predictedEndTranslation.height
                if screenPanelOpen {
                    if drag < -48 || predicted < -80 {
                        closeScreenPanel()
                    } else {
                        withAnimation(.timingCurve(0, 0, 0.2, 1, duration: 0.28)) {
                            screenPanelDragOffset = 0
                        }
                    }
                } else {
                    if drag > 44 || predicted > 80 {
                        openScreenPanel()
                    } else {
                        withAnimation(.timingCurve(0, 0, 0.2, 1, duration: 0.28)) {
                            screenPanelDragOffset = 0
                        }
                    }
                }
            }
    }

    private func openScreenPanel() {
        if !screenPanelOpen { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        screenPanelOpen = true
        screenPanelDragOffset = 0
        connections.setScreenListener(connectionId: connectionId, listener: screenState)
        if let session {
            requestScreen(session)
        }
    }

    private func closeScreenPanel() {
        screenPanelOpen = false
        screenPanelDragOffset = 0
        if let session { connections.stopScreen(session: session) }
    }

    private func requestScreen(_ session: DesktopSession) {
        let w = videoAreaSize.width > 0 ? Int(videoAreaSize.width) : Int(UIScreen.main.bounds.width)
        let h = videoAreaSize.height > 0 ? Int(videoAreaSize.height) : Int(UIScreen.main.bounds.height)
        connections.startScreen(session: session, viewportW: w, viewportH: h)
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

private struct InputViewTopKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct InputViewHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct InputViewFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

@MainActor
final class ScreenState: ObservableObject, ScreenListener {
    @Published var videoTrack: RTCVideoTrack?
    @Published var thumbnail: UIImage?
    @Published var metaWinW: Int = 0
    @Published var metaWinH: Int = 0
    @Published var metaScale: Float = 2.0
    @Published var metaX: Int = 0
    @Published var metaY: Int = 0
    @Published var metaW: Int = 0
    @Published var metaH: Int = 0

    func onVideoTrack(_ track: RTCVideoTrack) {
        videoTrack = track
    }

    func onThumbnail(sessionId: String, jpeg: Data) {
        thumbnail = UIImage(data: jpeg)
    }

    func onMeta(sessionId: String, winW: Int, winH: Int, scale: Float, x: Int, y: Int, w: Int, h: Int) {
        metaWinW = winW; metaWinH = winH; metaScale = scale
        metaX = x; metaY = y; metaW = w; metaH = h
    }

    func onScreenError(sessionId: String, message: String) {
        print("[chatput-screen] error: \(message)")
    }
}

private struct VideoRendererView: UIViewRepresentable {
    @Binding var track: RTCVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ uiView: RTCMTLVideoView, context: Context) {
        if let oldTrack = context.coordinator.currentTrack, oldTrack !== track {
            oldTrack.remove(uiView)
        }
        if let newTrack = track, newTrack !== context.coordinator.currentTrack {
            newTrack.add(uiView)
        }
        context.coordinator.currentTrack = track
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var currentTrack: RTCVideoTrack?
    }

    static func dismantleUIView(_ uiView: RTCMTLVideoView, coordinator: Coordinator) {
        if let track = coordinator.currentTrack {
            track.remove(uiView)
        }
    }
}

/// 缩略小地图：底图是整窗缩略图 + 红框视口 + 拖拽红框平移采集区域。
/// UIView + UIPanGestureRecognizer，meta 和手势自由竞争写入，触摸事件高频率自然占优。
private struct MinimapView: UIViewRepresentable {
    let thumbnail: UIImage?
    let winW, winH, vpX, vpY, vpW, vpH: Int
    let onViewportMove: (Int, Int) -> Void

    func makeUIView(context: Context) -> MinimapUIView {
        let v = MinimapUIView()
        v.onViewportMove = onViewportMove
        v.addGestureRecognizer(context.coordinator.pan)
        return v
    }

    func updateUIView(_ v: MinimapUIView, context: Context) {
        v.thumbnail = thumbnail
        v.winW = CGFloat(winW); v.winH = CGFloat(winH)
        v.vpX = CGFloat(vpX); v.vpY = CGFloat(vpY)
        v.vpW = CGFloat(vpW); v.vpH = CGFloat(vpH)
        v.onViewportMove = onViewportMove
        v.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator()
        c.pan.addTarget(c, action: #selector(Coordinator.handlePan(_:)))
        return c
    }

    final class Coordinator: NSObject {
        let pan = UIPanGestureRecognizer()
        var startVpX: CGFloat = 0
        var startVpY: CGFloat = 0

        @objc func handlePan(_ pan: UIPanGestureRecognizer) {
            guard let v = pan.view as? MinimapUIView,
                  v.winW > 0, v.winH > 0, v.vpW > 0, v.vpH > 0 else { return }
            let pt = pan.location(in: v)
            let sx = v.contentRect.width / v.winW
            let sy = v.contentRect.height / v.winH

            switch pan.state {
            case .began:
                let box = CGRect(x: v.contentRect.minX + v.vpX * sx,
                                 y: v.contentRect.minY + v.vpY * sy,
                                 width: v.vpW * sx, height: v.vpH * sy)
                guard box.contains(pt) else { pan.state = .failed; return }
                startVpX = v.vpX; startVpY = v.vpY
            case .changed:
                let trans = pan.translation(in: v)
                let nx = max(0, min(v.winW - v.vpW, startVpX + trans.x / sx))
                let ny = max(0, min(v.winH - v.vpH, startVpY + trans.y / sy))
                v.vpX = nx; v.vpY = ny
                v.onViewportMove?(Int(nx), Int(ny))
                v.setNeedsDisplay()
            default: break
            }
        }
    }
}

final class MinimapUIView: UIView {
    var thumbnail: UIImage?
    var winW: CGFloat = 0; var winH: CGFloat = 0
    var vpX: CGFloat = 0; var vpY: CGFloat = 0
    var vpW: CGFloat = 0; var vpH: CGFloat = 0
    var onViewportMove: ((Int, Int) -> Void)?
    var isDragging: Bool { dragging }

    fileprivate var contentRect: CGRect = .zero
    private var dragging = false
    private var dragTouchOffsetX: CGFloat = 0
    private var dragTouchOffsetY: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        recomputeContentRect()
    }

    private func recomputeContentRect() {
        guard winW > 0, winH > 0, bounds.width > 0, bounds.height > 0 else { return }
        let viewAspect = bounds.width / bounds.height
        let winAspect = winW / winH
        if winAspect > viewAspect {
            let drawH = bounds.width / winAspect
            contentRect = CGRect(x: 0, y: (bounds.height - drawH) / 2, width: bounds.width, height: drawH)
        } else {
            let drawW = bounds.height * winAspect
            contentRect = CGRect(x: (bounds.width - drawW) / 2, y: 0, width: drawW, height: bounds.height)
        }
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        recomputeContentRect()

        let drawRect = contentRect.isEmpty ? bounds : contentRect
        thumbnail?.draw(in: drawRect)

        guard !contentRect.isEmpty, vpW > 0, vpH > 0 else { return }
        let sx = contentRect.width / winW
        let sy = contentRect.height / winH
        let box = CGRect(x: contentRect.minX + vpX * sx,
                         y: contentRect.minY + vpY * sy,
                         width: vpW * sx, height: vpH * sy)
        UIColor.red.withAlphaComponent(0.2).setFill()
        UIBezierPath(rect: box).fill()
        UIColor.red.setStroke()
        let path = UIBezierPath(rect: box)
        path.lineWidth = 2
        path.stroke()
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let pt = touches.first?.location(in: self),
              winW > 0, vpW > 0, vpH > 0, !contentRect.isEmpty else { return }
        let sx = contentRect.width / winW; let sy = contentRect.height / winH
        let box = CGRect(x: contentRect.minX + vpX * sx, y: contentRect.minY + vpY * sy,
                         width: vpW * sx, height: vpH * sy)
        guard box.insetBy(dx: -15, dy: -15).contains(pt) else { return }
        dragging = true
        dragTouchOffsetX = pt.x - box.minX; dragTouchOffsetY = pt.y - box.minY
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard dragging, let pt = touches.first?.location(in: self) else { return }
        let sx = contentRect.width / winW; let sy = contentRect.height / winH
        let nx = max(0, min(winW - vpW, (pt.x - dragTouchOffsetX - contentRect.minX) / sx))
        let ny = max(0, min(winH - vpH, (pt.y - dragTouchOffsetY - contentRect.minY) / sy))
        vpX = nx; vpY = ny
        onViewportMove?(Int(nx), Int(ny))
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { dragging = false }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { dragging = false }
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
