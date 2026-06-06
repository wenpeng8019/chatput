package com.chatput.app

// region ── Imports ──────────────────────────────────────────────────────────

import android.Manifest
import android.animation.Animator
import android.animation.AnimatorListenerAdapter
import android.animation.ValueAnimator
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.hardware.Sensor
import android.hardware.SensorManager
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.ImageView
import android.widget.PopupWindow
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.updateLayoutParams
import androidx.core.view.updatePadding
import androidx.recyclerview.widget.LinearLayoutManager
import com.chatput.app.databinding.ActivityChatBinding

// endregion

// ═══════════════════════════════════════════════════════════════════════════════
// ChatActivity — 语音交互 + 远程桌面会话页
// ═══════════════════════════════════════════════════════════════════════════════
// 层级架构：
//   ChatActivity (orchestrator)
//     ├── VoiceComposer      — 语音按钮 (bindVoiceButton + cursor 手势)
//     ├── ComposerButtons     — 退格/回车 (bindBackspaceButton/EnterButton)
//     ├── TextInputPanel      — 文字输入 (bindTextInput + 滑动手势)
//     ├── ScreenCurtainCtrl   — 远程桌面幕布 (ScreenCurtainController)
//     │     └── ScreenPanel   — 视频渲染/触控 (ScreenPanelController)
//     ├── Header & Messages   — 顶栏菜单/消息列表
//     └── Lifecycle & Insets  — 生命周期/窗口 insets/连接监听
// ═══════════════════════════════════════════════════════════════════════════════

class ChatActivity : AppCompatActivity(), ConnectionManager.Observer {

    // region ── Constants ────────────────────────────────────────────────────

    companion object {
        const val EXTRA_CONNECTION_ID = "connection_id"
        const val EXTRA_SESSION_ID = "session_id"
        private const val CLEAR_HOLD_DURATION_MS = 750L
        private const val HINT_DEFAULT = "按住说话"
        private const val HINT_ENGLISH = "请说英文"
        private const val TALK_TAP_MAX_MS = 180L

        // 光标拖动手势参数（与 iOS TalkUX 对齐）
        private const val CURSOR_ACTIVATION_DP = 28f
        private const val CURSOR_STEP_DP = 24f
        private const val CURSOR_SWIPE_TRIGGER_DP = 32f
        private const val CURSOR_VERTICAL_BIAS = 1.8f
        private const val CURSOR_CONTINUOUS_DP = 96f
        private const val CURSOR_REPEAT_MAX_MS = 200L
        private const val CURSOR_REPEAT_MIN_MS = 40L
        private const val COMPOSER_LIFT_DP = 56f
    }

    // endregion
    // region ── Fields ───────────────────────────────────────────────────────

    private lateinit var binding: ActivityChatBinding
    private lateinit var adapter: MessageAdapter
    private lateinit var speech: SpeechHelper
    private var screenCurtain: ScreenCurtainController? = null
    private var shakeDetector: ShakeDetector? = null
    private val dpadViews = mutableListOf<View>()  // D-pad 四向方块
    private var debugHotZones = false               // 调试：显示隐藏热区颜色
    private var titleTapCount = 0; private var titleTapFirst = 0L
    private val mainHandler = Handler(Looper.getMainLooper())

    private var session: Session? = null
    private var connectionId: String = ""
    private var sessionId: String = ""
    private var lastInputHeightPx = 0

    // text input mode
    private var inputVisible = false
    private var englishModeAvailable = false

    // long-press progress state
    private var clearAnimator: ValueAnimator? = null
    private var clearCancelled = false; private var clearCompleted = false
    private var enterAnimator: ValueAnimator? = null
    private var enterCancelled = false; private var enterCompleted = false

    // cursor drag state
    private var gestureStartX = 0f; private var gestureStartY = 0f
    private var inCursorMode = false
    private var cursorVertical = false; private var cursorContinuous = false
    private var cursorDelta = 0f; private var cursorOriginX = 0f; private var cursorAbsX = 0f
    private var lastStepIndex = 0; private var cursorRepeating = false
    private var talkDownAt = 0L; private var talkMode = SpeechHelper.Mode.DEFAULT
    private var isTalkingActive = false
    private var lastTalkTapUpAt = 0L; private var lastTalkTapX = 0f; private var lastTalkTapY = 0f

    private val cursorRepeatRunnable = object : Runnable {
        override fun run() {
            if (!inCursorMode) return
            val cont = cursorContinuousDelta()
            if (kotlin.math.abs(cont) >= cursorContinuousPx()) {
                sendAction(cursorActionFor(cont > 0))
                v_haptic()
                mainHandler.postDelayed(this, cursorRepeatInterval())
            } else {
                cursorRepeating = false
                if (cursorContinuous) { cursorContinuous = false; refreshDirectionHints() }
            }
        }
    }
    private val hintResetRunnable = Runnable { binding.hint.text = currentIdleHint() }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Lifecycle
    // ═══════════════════════════════════════════════════════════════════════════

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        applySystemBarAppearance()
        binding = ActivityChatBinding.inflate(layoutInflater)
        setContentView(binding.root)
        applyEdgeToEdgeInsets()

        connectionId = intent.getStringExtra(EXTRA_CONNECTION_ID).orEmpty()
        sessionId = intent.getStringExtra(EXTRA_SESSION_ID).orEmpty()
        session = ConnectionManager.sessionById(connectionId, sessionId)
        if (session == null) { finish(); return }

        binding.appTitle.text = session!!.app.ifBlank { "ChatPUT" }
        binding.subtitle.text = session!!.device.ifBlank { session!!.title.ifBlank { "当前窗口" } }
        // 工程菜单不绑定在 title 的 OnClickListener 上（否则 title clickable 会屏蔽拖拽）。
        // 改为在 dispatchTouchEvent 中拦截，事件到达子 View 前计数，不干扰拖拽。

        adapter = MessageAdapter(session!!.messages,
            onResend = { a, p -> resendMessage(a, p) },
            onLongPress = { a, p -> showMessageActions(a, p) })
        binding.list.layoutManager = LinearLayoutManager(this).apply { stackFromEnd = true }
        binding.list.adapter = adapter; scrollToBottom()

        speech = SpeechHelper(this)
        englishModeAvailable = SpeechHelper.hasEnglishModel(this)

        bindVoiceButton(); bindBackspaceButton(); bindEnterButton()
        bindDragHandle(); bindTextInput()
        binding.btnHeaderMenu.setOnClickListener { showHeaderMenu(it) }
        setupScreenCurtain()

        shakeDetector = ShakeDetector { sendAction("undo") }.also {
            val sm = getSystemService(SENSOR_SERVICE) as SensorManager
            sm.registerListener(it, sm.getDefaultSensor(Sensor.TYPE_ACCELEROMETER), SensorManager.SENSOR_DELAY_GAME)
        }

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (inputVisible) hideTextInput() else { isEnabled = false; onBackPressedDispatcher.onBackPressed() }
            }
        })
    }

    override fun onResume() {
        super.onResume(); ConnectionManager.addObserver(this)
        val s = ConnectionManager.sessionById(connectionId, sessionId)
        if (s == null || !ConnectionManager.isConnected) { returnToSessionList(); return }
        session = s
    }

    override fun onPause() { super.onPause(); ConnectionManager.removeObserver(this) }

    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
        if (event.actionMasked == MotionEvent.ACTION_UP && ::binding.isInitialized) {
            val loc = IntArray(2); binding.appTitle.getLocationOnScreen(loc)
            val l = loc[0]; val t = loc[1]
            if (event.rawX >= l && event.rawX <= l + binding.appTitle.width &&
                event.rawY >= t && event.rawY <= t + binding.appTitle.height) {
                val now = System.currentTimeMillis()
                if (now - titleTapFirst > 2000) { titleTapCount = 0; titleTapFirst = now }
                titleTapCount++
                if (titleTapCount >= 5) { titleTapCount = -99; showEngineeringMenu(binding.appTitle) }
            }
        }
        return super.dispatchTouchEvent(event)
    }

    override fun onDestroy() {
        super.onDestroy()
        mainHandler.removeCallbacksAndMessages(null)
        clearAnimator?.cancel(); enterAnimator?.cancel()
        shakeDetector?.let { (getSystemService(SENSOR_SERVICE) as SensorManager).unregisterListener(it) }
        screenCurtain?.release()
        speech.destroy()
    }

    private fun returnToSessionList() {
        startActivity(Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK) })
        finish()
    }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Voice Composer (voice button + cursor gestures)
    // ═══════════════════════════════════════════════════════════════════════════

    private fun bindVoiceButton() {
        val cfg = android.view.ViewConfiguration.get(this)
        val dragActivationPx = maxOf(cfg.scaledTouchSlop * 2f, CURSOR_ACTIVATION_DP.dpF)
        val tapTimeoutMs = android.view.ViewConfiguration.getDoubleTapTimeout().toLong()
        val doubleTapSlopPx = cfg.scaledDoubleTapSlop.toFloat()

        binding.btnTalk.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    val isDoubleTap = englishModeAvailable &&
                        event.eventTime - lastTalkTapUpAt <= tapTimeoutMs &&
                        kotlin.math.hypot(event.rawX - lastTalkTapX, event.rawY - lastTalkTapY) <= doubleTapSlopPx
                    gestureStartX = event.rawX; gestureStartY = event.rawY
                    talkDownAt = event.eventTime
                    talkMode = if (isDoubleTap) SpeechHelper.Mode.ENGLISH else SpeechHelper.Mode.DEFAULT
                    inCursorMode = false; cursorDelta = 0f; lastStepIndex = 0
                    cursorOriginX = talkCenterX(); cursorAbsX = event.rawX; cursorRepeating = false
                    startTalking(v, talkMode); true
                }
                MotionEvent.ACTION_MOVE -> {
                    cursorAbsX = event.rawX
                    if (!inCursorMode) {
                        val dx = event.rawX - gestureStartX; val dy = event.rawY - gestureStartY
                        if (kotlin.math.hypot(dx, dy) > dragActivationPx) {
                            cursorVertical = kotlin.math.abs(dy) > kotlin.math.abs(dx) * CURSOR_VERTICAL_BIAS
                            enterCursorMode()
                            gestureStartX = event.rawX; gestureStartY = event.rawY
                        }
                    }
                    if (inCursorMode) {
                        if (cursorVertical) updateCursorSwipe(event.rawY - gestureStartY)
                        else updateCursorDrag(event.rawX - gestureStartX)
                    }; true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (inCursorMode) endCursorMode(v) else {
                        if (event.eventTime - talkDownAt <= TALK_TAP_MAX_MS) {
                            cancelTalking(v)
                            if (talkMode == SpeechHelper.Mode.DEFAULT && englishModeAvailable) {
                                lastTalkTapUpAt = event.eventTime; lastTalkTapX = event.rawX; lastTalkTapY = event.rawY
                                showTransientHint("再按一次进入英文输入")
                            } else { lastTalkTapUpAt = 0L; binding.hint.text = HINT_DEFAULT }
                        } else { lastTalkTapUpAt = 0L; stopTalking(v) }
                    }; true
                }
                else -> false
            }
        }
    }

    // -- cursor mode helpers

    private fun refreshDirectionHints() = binding.directionHints.setState(
        talking = isTalkingActive, cursorMode = inCursorMode,
        vertical = cursorVertical, continuous = cursorContinuous)

    private fun enterCursorMode() {
        mainHandler.removeCallbacks(hintResetRunnable)
        inCursorMode = true; lastStepIndex = 0; cursorRepeating = false; cursorContinuous = false
        isTalkingActive = false; speech.cancel(); setOrbActive(false); refreshDirectionHints()
        binding.hint.text = if (cursorVertical) "↑ 上滑松手切行 ↓" else "← 拖动移动光标 →"
    }

    private fun cursorActionFor(positive: Boolean) = when {
        cursorVertical && positive -> "cursorDown"; cursorVertical -> "cursorUp"
        positive -> "cursorRight"; else -> "cursorLeft"
    }

    private fun updateCursorDrag(delta: Float) {
        cursorDelta = delta
        val stepPx = CURSOR_STEP_DP.dpF; val stepIndex = Math.round(delta / stepPx)
        if (stepIndex != lastStepIndex) {
            val positive = stepIndex > lastStepIndex
            repeat(kotlin.math.abs(stepIndex - lastStepIndex)) { sendAction(cursorActionFor(positive)); cursorStepHaptic() }
            lastStepIndex = stepIndex
        }
        if (kotlin.math.abs(cursorContinuousDelta()) >= cursorContinuousPx()) {
            if (!cursorRepeating) { cursorRepeating = true; mainHandler.postDelayed(cursorRepeatRunnable, cursorRepeatInterval()) }
            if (!cursorContinuous) { cursorContinuous = true; refreshDirectionHints() }
        } else {
            cursorRepeating = false; mainHandler.removeCallbacks(cursorRepeatRunnable)
            if (cursorContinuous) { cursorContinuous = false; refreshDirectionHints() }
        }
    }

    private fun updateCursorSwipe(delta: Float) {
        cursorDelta = delta
        val trigger = CURSOR_SWIPE_TRIGGER_DP.dpF
        binding.hint.text = if (kotlin.math.abs(delta) >= trigger)
            (if (delta > 0) "↓ 松手切到下一行" else "↑ 松手切到上一行") else "↑ 上滑松手切行 ↓"
    }

    private fun cursorRepeatInterval(): Long {
        val travel = kotlin.math.abs(cursorContinuousDelta()); val start = cursorContinuousPx()
        val full = start + CURSOR_STEP_DP.dpF * 8f
        return (CURSOR_REPEAT_MAX_MS - (CURSOR_REPEAT_MAX_MS - CURSOR_REPEAT_MIN_MS) * ((travel - start) / (full - start)).coerceIn(0f, 1f)).toLong()
    }

    private fun cursorContinuousDelta() = cursorAbsX - cursorOriginX
    private fun talkCenterX(): Float {
        val loc = IntArray(2); binding.btnTalk.getLocationOnScreen(loc); return loc[0] + binding.btnTalk.width / 2f
    }

    private fun cursorContinuousPx(): Float {
        val talk = binding.btnTalk; val side = binding.btnBackspace
        if (talk.width == 0 || side.width == 0) return CURSOR_CONTINUOUS_DP.dpF
        return kotlin.math.abs((talk.x + talk.width / 2f) - (side.x + side.width / 2f))
    }

    private fun endCursorMode(v: View) {
        mainHandler.removeCallbacks(hintResetRunnable)
        if (cursorVertical && kotlin.math.abs(cursorDelta) >= CURSOR_SWIPE_TRIGGER_DP.dpF) { sendAction(cursorActionFor(cursorDelta > 0)); cursorStepHaptic() }
        inCursorMode = false; cursorRepeating = false; cursorContinuous = false; cursorDelta = 0f
        mainHandler.removeCallbacks(cursorRepeatRunnable); refreshDirectionHints()
        v.isPressed = false; binding.hint.text = currentIdleHint()
    }

    private fun cursorStepHaptic() { v_haptic(); if (cursorVertical) mainHandler.postDelayed({ v_haptic() }, 55) }
    private fun v_haptic() = binding.btnTalk.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP, HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING)

    // -- talking

    private fun startTalking(v: View, mode: SpeechHelper.Mode) {
        mainHandler.removeCallbacks(hintResetRunnable)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) { Toast.makeText(this, "请先授予录音权限", Toast.LENGTH_SHORT).show(); return }
        if (!isInputAvailable()) return
        v.isPressed = true; setOrbActive(true); isTalkingActive = true; refreshDirectionHints()
        binding.hint.text = if (mode == SpeechHelper.Mode.ENGLISH) HINT_ENGLISH else "正在听…"
        speech.start(object : SpeechHelper.Callback {
            override fun onPartial(text: String) { binding.hint.text = text }
            override fun onResult(text: String) {
                binding.hint.text = HINT_DEFAULT
                if (text.isNotBlank()) session?.let { ConnectionManager.sendText(it, text) }
            }
            override fun onError(message: String) { binding.hint.text = HINT_DEFAULT; Toast.makeText(this@ChatActivity, message, Toast.LENGTH_SHORT).show() }
        }, mode)
    }

    private fun stopTalking(v: View) { mainHandler.removeCallbacks(hintResetRunnable); v.isPressed = false; setOrbActive(false); isTalkingActive = false; refreshDirectionHints(); speech.stop() }
    private fun cancelTalking(v: View) { mainHandler.removeCallbacks(hintResetRunnable); v.isPressed = false; setOrbActive(false); isTalkingActive = false; refreshDirectionHints(); speech.cancel() }

    private fun setOrbActive(active: Boolean) {
        binding.btnTalk.animate().scaleX(if (active) 0.93f else 1f).scaleY(if (active) 0.93f else 1f).setDuration(130).start()
        binding.orbHalo.animate().alpha(if (active) 1f else 0f).scaleX(if (active) 1.12f else 0.85f).scaleY(if (active) 1.12f else 0.85f).setDuration(180).start()
    }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Composer Buttons (backspace + enter, long-press hold)
    // ═══════════════════════════════════════════════════════════════════════════

    private fun bindBackspaceButton() {
        binding.btnBackspace.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { v.isPressed = true; startClearHold() }
                MotionEvent.ACTION_UP -> { v.isPressed = false; if (!stopClearHold()) sendAction("backspace") }
                MotionEvent.ACTION_CANCEL -> { v.isPressed = false; stopClearHold() }
            }; true
        }
    }

    private fun bindEnterButton() {
        binding.btnEnter.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { v.isPressed = true; startEnterHold() }
                MotionEvent.ACTION_UP -> { v.isPressed = false; if (!stopEnterHold()) sendAction("shiftEnter") }
                MotionEvent.ACTION_CANCEL -> { v.isPressed = false; stopEnterHold() }
            }; true
        }
    }

    // -- hold progress

    private fun startClearHold() {
        clearCancelled = false; clearCompleted = false; binding.clearProgress.progress = 0; binding.clearProgress.visibility = View.VISIBLE
        clearAnimator?.cancel()
        clearAnimator = ValueAnimator.ofInt(0, 100).apply {
            duration = CLEAR_HOLD_DURATION_MS
            addUpdateListener { binding.clearProgress.progress = it.animatedValue as Int }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationCancel(a: Animator) { clearCancelled = true }
                override fun onAnimationEnd(a: Animator) {
                    binding.clearProgress.visibility = View.GONE
                    if (!clearCancelled) { clearCompleted = true; binding.btnBackspace.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS); sendAction("clear"); showTransientHint("已清空") }
                }
            }); start()
        }
    }

    private fun stopClearHold(): Boolean { clearAnimator?.cancel(); clearAnimator = null; binding.clearProgress.visibility = View.GONE; return clearCompleted }

    private fun startEnterHold() {
        enterCancelled = false; enterCompleted = false; binding.enterProgress.progress = 0; binding.enterProgress.visibility = View.VISIBLE
        enterAnimator?.cancel()
        enterAnimator = ValueAnimator.ofInt(0, 100).apply {
            duration = CLEAR_HOLD_DURATION_MS
            addUpdateListener { binding.enterProgress.progress = it.animatedValue as Int }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationCancel(a: Animator) { enterCancelled = true }
                override fun onAnimationEnd(a: Animator) {
                    binding.enterProgress.visibility = View.GONE
                    if (!enterCancelled) { enterCompleted = true; binding.btnEnter.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS); sendAction("enter") }
                }
            }); start()
        }
    }

    private fun stopEnterHold(): Boolean { enterAnimator?.cancel(); enterAnimator = null; binding.enterProgress.visibility = View.GONE; return enterCompleted }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Text Input Panel (drag-to-open, text input, swipe gestures)
    // ═══════════════════════════════════════════════════════════════════════════

    // -- drag handle (pull up to show text input)

    private fun bindDragHandle() = binding.dragHandle.setOnTouchListener(dragGestureListener())

    private fun dragGestureListener(): View.OnTouchListener {
        val slop = android.view.ViewConfiguration.get(this).scaledTouchSlop; val pullMax = 96f.dpF
        var startY = 0f; var startX = 0f; var triggered = false; var blocked = false
        return View.OnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { blocked = isInTalkButtonSwipeZone(event.rawX); startY = event.rawY; startX = event.rawX; triggered = false; true }
                MotionEvent.ACTION_MOVE -> {
                    if (blocked) return@OnTouchListener true
                    if (!triggered) { val pulled = startY - event.rawY; if (pulled > 0) applyComposerPull(pulled / pullMax); if (pulled > pullMax * 0.55f) { triggered = true; showTextInput() } }; true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (blocked) { blocked = false; return@OnTouchListener true }
                    if (!triggered) { if (startY - event.rawY < slop) { if (isWithinComposer(startX, startY)) showTextInput() } else snapComposerBack() }; true
                }
                else -> true
            }
        }
    }

    private fun isInTalkButtonSwipeZone(rawX: Float): Boolean {
        val loc = IntArray(2); binding.composerCard.getLocationOnScreen(loc)
        val cx = if (binding.composerCard.width > 0) loc[0] + binding.composerCard.width / 2f else resources.displayMetrics.widthPixels / 2f
        return kotlin.math.abs(rawX - cx) <= 70f.dpF
    }

    private fun isWithinComposer(rawX: Float, rawY: Float): Boolean {
        val loc = IntArray(2); binding.composerCard.getLocationOnScreen(loc)
        return rawX >= loc[0] && rawX <= loc[0] + binding.composerCard.width && rawY >= loc[1] && rawY <= loc[1] + binding.composerCard.height
    }

    private fun applyComposerPull(progress: Float) {
        val p = progress.coerceIn(0f, 1f); val ty = -COMPOSER_LIFT_DP.dpF * p; val a = 1f - p
        listOf(binding.composerCard, binding.hint, binding.grabDecor).forEach { it.translationY = ty; it.alpha = a }
    }

    private fun snapComposerBack() {
        listOf(binding.composerCard, binding.hint, binding.grabDecor).forEach {
            it.animate().translationY(0f).alpha(1f).setDuration(200).setInterpolator(android.view.animation.DecelerateInterpolator()).start()
        }
    }

    // -- text input field

    private fun bindTextInput() {
        binding.btnTextMic.setOnClickListener { hideTextInput() }
        binding.btnSend.setOnClickListener { sendTypedText() }
        binding.inputText.setOnEditorActionListener { _, actionId, _ -> if (actionId == EditorInfo.IME_ACTION_SEND) { sendTypedText(); true } else false }
        bindTextInputSwipeDown()
    }

    /** 文本输入 EditText 双向手势：下滑→切回语音，上滑（幕布打开时）→关闭幕布。 */
    private fun bindTextInputSwipeDown() {
        val swipeMin = ViewConfiguration.get(this).scaledTouchSlop.toFloat()
        var startY = 0f; var swipeDir = 0 // 0=未定, -1=上, 1=下
        binding.inputText.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> { startY = event.rawY; swipeDir = 0; view.onTouchEvent(event); true }
                MotionEvent.ACTION_MOVE -> {
                    val dy = event.rawY - startY
                    if (swipeDir == 0 && kotlin.math.abs(dy) > swipeMin) { swipeDir = if (dy > 0) 1 else -1; cancelEditTextTouch(view, event) }
                    if (swipeDir != 0) true else { view.onTouchEvent(event); true }
                }
                MotionEvent.ACTION_UP -> {
                    val dy = event.rawY - startY
                    when { swipeDir == 1 && dy > 28f.dpF -> hideTextInput(); swipeDir == -1 && dy < -28f.dpF && screenCurtain?.opened == true -> screenCurtain?.close(); else -> view.onTouchEvent(event) }
                    swipeDir = 0; true
                }
                MotionEvent.ACTION_CANCEL -> { swipeDir = 0; view.onTouchEvent(event); true }
                else -> { view.onTouchEvent(event); true }
            }
        }
    }

    private fun cancelEditTextTouch(view: View, event: MotionEvent) {
        MotionEvent.obtain(event.downTime, event.eventTime, MotionEvent.ACTION_CANCEL, event.x, event.y, event.metaState).let {
            view.onTouchEvent(it); it.recycle()
        }
    }

    // -- show / hide

    private fun showTextInput() {
        if (inputVisible) return; inputVisible = true
        val lift = -COMPOSER_LIFT_DP.dpF; val deco = android.view.animation.DecelerateInterpolator()
        setDragZonesEnabled(false)
        listOf(binding.composerCard to 220L, binding.hint to 220L, binding.grabDecor to 180L).forEach { (v, dur) ->
            v.animate().translationY(lift).alpha(0f).setDuration(dur).setInterpolator(deco)
                .withEndAction { v.visibility = View.INVISIBLE }.start()
        }
        binding.textInputCard.apply { alpha = 0f; visibility = View.VISIBLE; animate().alpha(1f).setDuration(220).setStartDelay(60).start() }
        binding.inputText.requestFocus(); imm().showSoftInput(binding.inputText, InputMethodManager.SHOW_IMPLICIT)
        binding.composerCard.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
    }

    private fun hideTextInput() {
        if (!inputVisible) return; inputVisible = false
        imm().hideSoftInputFromWindow(binding.inputText.windowToken, 0); binding.inputText.clearFocus()
        binding.textInputCard.animate().alpha(0f).setDuration(150).withEndAction { binding.textInputCard.visibility = View.GONE }.start()
        listOf(binding.composerCard, binding.hint, binding.grabDecor).forEach { v -> v.visibility = View.VISIBLE; v.animate().translationY(0f).alpha(1f).setDuration(240).setInterpolator(android.view.animation.DecelerateInterpolator()).setStartDelay(40).start() }
        setDragZonesEnabled(true)
    }

    private fun setDragZonesEnabled(enabled: Boolean) { binding.dragHandle.isEnabled = enabled; binding.dragHandle.isClickable = enabled }
    private fun imm(): InputMethodManager = getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager

    // -- send

    private fun sendTypedText() {
        val text = binding.inputText.text?.toString()?.trim().orEmpty()
        if (text.isBlank() || !isInputAvailable()) return
        session?.let { ConnectionManager.sendText(it, text) }; binding.inputText.text?.clear()
    }

    private fun isInputAvailable(): Boolean = session?.inputAvailable != false && ConnectionManager.isConnected

    private fun sendAction(action: String) {
        if (!isInputAvailable()) return
        session?.let { ConnectionManager.sendAction(it, action) }
    }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Screen Curtain (remote desktop video panel)
    // ═══════════════════════════════════════════════════════════════════════════

    private fun setupScreenCurtain() {
        val s = session ?: return
        val panel = ScreenPanelController(binding.screenRenderer, binding.minimap, binding.screenStatus, binding.screenCover)
        panel.init(DesktopConnection.eglBaseContext()); panel.bind(s.connectionId, s)
        screenCurtain = ScreenCurtainController(binding.screenPanel, binding.screenShadow, binding.screenGrab, binding.chatHeader, panel).also {
            it.bindCollapseZone(binding.screenCollapseZone)
        }
    }

    private fun openScreenView() {
        if (!ConnectionManager.isConnected) { Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show(); return }
        screenCurtain?.open()
    }

    private fun updateScreenCurtainLift(imeBottom: Int) {
        val inputH = binding.textInputCard.height.takeIf { it > 0 } ?: lastInputHeightPx
        if (inputH > 0) lastInputHeightPx = inputH
        screenCurtain?.updateKeyboardLift(binding.root.height, imeBottom, inputH)
    }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Input State (normal vs input-lost D-pad mode)
    // ═══════════════════════════════════════════════════════════════════════════

    private fun refreshInputState() {
        val available = session?.inputAvailable != false
        android.util.Log.d("chatput-input", "refreshState available=$available inputAvail=${session?.inputAvailable}")
        binding.inputText.isEnabled = available; binding.btnSend.isEnabled = available
        if (available) { bindNormalControls(); binding.hint.text = currentIdleHint() }
        else { bindInputLostControls(); binding.hint.text = "↑↓←→ 移动光标" }
    }

    private fun bindNormalControls() {
        (binding.btnTalk.getChildAt(0) as? ImageView)?.setImageResource(R.drawable.ic_mic)
        (binding.btnBackspace.getChildAt(0) as? ImageView)?.setImageResource(R.drawable.ic_nav_backspace)
        (binding.btnEnter.getChildAt(0) as? ImageView)?.setImageResource(R.drawable.ic_nav_enter)
        binding.btnTalk.setOnTouchListener(null); binding.btnBackspace.setOnTouchListener(null); binding.btnEnter.setOnTouchListener(null)
        bindVoiceButton(); bindBackspaceButton(); bindEnterButton()
        dpadViews.forEach { (it.parent as? ViewGroup)?.removeView(it) }
        dpadViews.clear()
        refreshDirectionHints()
        binding.grabDecor.visibility = View.VISIBLE; binding.dragHandle.isEnabled = true
    }

    private fun bindInputLostControls() {
        binding.composerCard.clipChildren = false
        binding.composerCard.clipToOutline = false
        (binding.btnTalk.getChildAt(0) as? ImageView)?.setImageResource(R.drawable.ic_dpad)
        (binding.btnBackspace.getChildAt(0) as? ImageView)?.setImageResource(R.drawable.ic_nav_esc)
        binding.btnTalk.setOnTouchListener(null)
        binding.btnBackspace.setOnTouchListener(null)
        binding.btnBackspace.setOnClickListener { v_haptic(); sendAction("escape") }
        binding.btnEnter.setOnTouchListener(null)
        binding.btnEnter.setOnClickListener { v_haptic(); sendAction("enter") }
        expandDpadTouchArea()
        // D-pad 模式不显示左右圆点
        binding.directionHints.setState(talking = false, cursorMode = false, vertical = false, continuous = false, dpadMode = true)
        // 隐藏文本输入相关：上拉把手、圆角弧线装饰、拖拽感应
        binding.grabDecor.visibility = View.INVISIBLE
        binding.dragHandle.isEnabled = false
    }

    /**
     * D-pad 四向触控热区：在 btnTalk 所在的 ConstraintLayout 内创建四个 r×r 方块，
     * 分别约束到 btnTalk 的上/下/左/右边，使用 ConstraintLayout.LayoutParams 确保
     * 约束布局正确计算位置。
     */
    /**
     * D-pad 四向触控热区：直接加到 root ConstraintLayout（全屏，无 padding），
     * 用 getLocationOnScreen 算绝对坐标 → translationX/Y 落位，不依赖任何父层 layout。
     */
    private fun expandDpadTouchArea() {
        val btn = binding.btnTalk
        val root = binding.root
        root.clipChildren = false
        btn.post {
            val r = btn.width / 2
            val btnLoc = IntArray(2); val rootLoc = IntArray(2)
            btn.getLocationOnScreen(btnLoc)
            root.getLocationOnScreen(rootLoc)
            val bx = (btnLoc[0] - rootLoc[0]).toFloat()
            val by = (btnLoc[1] - rootLoc[1]).toFloat()
            val bw = btn.width.toFloat(); val bh = btn.height.toFloat()
            android.util.Log.d("chatput-dpad", "r=$r bx=$bx by=$by bw=$bw bh=$bh")
            val h = r / 2f  // 半边长
            listOf(
                Triple("cursorUp",    bx + h,   by - h),
                Triple("cursorDown",  bx + h,   by + bh - h),
                Triple("cursorLeft",  bx - h,   by + h),
                Triple("cursorRight", bx + bw - h, by + h),
            ).forEach { (action, x, y) ->
                val v = View(this@ChatActivity).apply {
                    layoutParams = ViewGroup.LayoutParams(r, r)
                    translationX = x; translationY = y
                    setOnClickListener { sendAction(action); v_haptic() }
                }
                dpadViews.add(v); root.addView(v)
            }
            refreshDebugHotZones()
        }
    }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Header Menu & Messages
    // ═══════════════════════════════════════════════════════════════════════════

    /** 工程菜单：标题连点 5 次弹出 AlertDialog，多选不关。 */
    private fun showEngineeringMenu(anchor: View) {
        titleTapCount = 0
        val items = arrayOf("透明热区", "文本/方向交互切换")
        val checked = booleanArrayOf(debugHotZones, session?.inputAvailable == false)
        android.app.AlertDialog.Builder(this)
            .setTitle("工程菜单")
            .setMultiChoiceItems(items, checked) { _, which, isChecked ->
                when (which) {
                    0 -> { debugHotZones = isChecked; refreshDebugHotZones() }
                    1 -> { session?.inputAvailable = !isChecked; refreshInputState() }
                }
            }
            .setPositiveButton("关闭", null)
            .show()
            .apply { setCanceledOnTouchOutside(false) }
    }

    /** 根据 debugHotZones 开关显示/隐藏所有隐藏热区颜色。 */
    private fun refreshDebugHotZones() {
        val colors = intArrayOf(0x40FF0000.toInt(), 0x4000FF00.toInt(), 0x400000FF.toInt(), 0x40FFFF00.toInt())
        dpadViews.forEachIndexed { i, v -> v.setBackgroundColor(if (debugHotZones) colors[i % 4] else Color.TRANSPARENT) }
        binding.screenCollapseZone.setBackgroundColor(if (debugHotZones) 0x80FF0000.toInt() else Color.TRANSPARENT)
        binding.dragHandle.setBackgroundColor(if (debugHotZones) 0x4000FF00.toInt() else Color.TRANSPARENT)
    }

    private fun showHeaderMenu(anchor: View) {
        anchor.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        val content = layoutInflater.inflate(R.layout.popup_header_actions, binding.root, false)
        val popup = PopupWindow(content, ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, true).apply { isOutsideTouchable = true; setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT)) }
        content.findViewById<View>(R.id.action_view_screen).setOnClickListener { popup.dismiss(); openScreenView() }
        content.findViewById<View>(R.id.action_undo).setOnClickListener { popup.dismiss(); sendAction("undo") }
        content.findViewById<View>(R.id.action_select_all).setOnClickListener { popup.dismiss(); sendAction("selectAll") }
        content.findViewById<View>(R.id.action_clear).setOnClickListener { popup.dismiss(); sendAction("clear"); showTransientHint("已清空") }
        content.measure(View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        popup.showAsDropDown(anchor, anchor.width - content.measuredWidth + 14.dp, 8.dp)
    }

    private fun resendMessage(anchor: View, position: Int) {
        val msg = session?.messages?.getOrNull(position) ?: return
        if (!isInputAvailable()) return
        anchor.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        session?.let { ConnectionManager.resendText(it, msg.text) }; showSentBalloon(anchor, "已发送")
    }

    private fun showMessageActions(anchor: View, position: Int) {
        anchor.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        val content = layoutInflater.inflate(R.layout.popup_message_actions, binding.root, false)
        val popup = PopupWindow(content, ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, true).apply { isOutsideTouchable = true; setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT)) }
        content.findViewById<View>(R.id.action_resend).setOnClickListener { popup.dismiss(); resendMessage(anchor, position) }
        content.findViewById<View>(R.id.action_delete).setOnClickListener { popup.dismiss(); deleteMessage(position) }
        content.measure(View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        popup.showAsDropDown(anchor, (anchor.width - content.measuredWidth) / 2, -(anchor.height + content.measuredHeight - 8.dp))
    }

    private fun deleteMessage(position: Int) {
        session?.messages?.let { if (position in it.indices) { it.removeAt(position); adapter.notifyItemRemoved(position) } }
    }

    private fun showSentBalloon(anchor: View, text: String) {
        val container = layoutInflater.inflate(R.layout.balloon_sent, binding.root, false) as ViewGroup
        val balloon = container.findViewById<TextView>(R.id.balloon_text).apply { this.text = text }
        val popup = PopupWindow(container, ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT, false).apply { isClippingEnabled = false; setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT)) }
        container.measure(View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED), View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
        popup.showAsDropDown(anchor, -(container.measuredWidth + 10.dp), -(anchor.height / 2 + (container.measuredHeight - balloon.measuredHeight) + balloon.measuredHeight / 2))
        balloon.alpha = 0f; balloon.animate().alpha(1f).setDuration(140).withEndAction {
            balloon.animate().alpha(0f).translationY((-22f).dpF).setStartDelay(540).setDuration(460).withEndAction { if (!isFinishing) popup.dismiss() }.start()
        }.start()
    }

    // -- hint helpers

    private fun showTransientHint(text: String) { binding.hint.text = text; mainHandler.removeCallbacks(hintResetRunnable); mainHandler.postDelayed(hintResetRunnable, 1_200) }
    private fun currentIdleHint(): String = if (binding.btnTalk.isPressed && !inCursorMode && talkMode == SpeechHelper.Mode.ENGLISH) HINT_ENGLISH else HINT_DEFAULT
    private fun scrollToBottom() { if (adapter.itemCount > 0) binding.list.scrollToPosition(adapter.itemCount - 1) }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Window Insets & System UI
    // ═══════════════════════════════════════════════════════════════════════════

    private fun applyEdgeToEdgeInsets() {
        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val tappable = insets.getInsets(WindowInsetsCompat.Type.tappableElement())
            val gestures = insets.getInsets(WindowInsetsCompat.Type.systemGestures())
            val imeVisible = insets.isVisible(WindowInsetsCompat.Type.ime())
            if (inputVisible && !imeVisible) hideTextInput()
            val imeBottom = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            binding.textInputCard.updateLayoutParams<ViewGroup.MarginLayoutParams> { bottomMargin = imeBottom }
            val visualBottomInset = when { tappable.bottom > 0 -> tappable.bottom; gestures.bottom > 0 -> gestures.bottom / 2; else -> systemBars.bottom / 2 }
            binding.chatHeader.updateLayoutParams<ViewGroup.MarginLayoutParams> { topMargin = 18.dp + systemBars.top }
            binding.list.updatePadding(top = 12.dp, bottom = 8.dp)
            binding.hint.updateLayoutParams<ViewGroup.MarginLayoutParams> { bottomMargin = 8.dp }
            binding.composerCard.updateLayoutParams<ViewGroup.MarginLayoutParams> { bottomMargin = 2.dp + visualBottomInset }
            updateScreenCurtainLift(imeBottom); insets
        }
        ViewCompat.setWindowInsetsAnimationCallback(binding.root, object : androidx.core.view.WindowInsetsAnimationCompat.Callback(
            androidx.core.view.WindowInsetsAnimationCompat.Callback.DISPATCH_MODE_CONTINUE_ON_SUBTREE) {
            override fun onProgress(insets: WindowInsetsCompat, running: List<androidx.core.view.WindowInsetsAnimationCompat>): WindowInsetsCompat {
                binding.textInputCard.updateLayoutParams<ViewGroup.MarginLayoutParams> { bottomMargin = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom }
                updateScreenCurtainLift(insets.getInsets(WindowInsetsCompat.Type.ime()).bottom); return insets
            }
        })
    }

    private fun applySystemBarAppearance() {
        val lightBars = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK != Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, window.decorView)?.apply { isAppearanceLightStatusBars = lightBars; isAppearanceLightNavigationBars = lightBars }
    }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - ConnectionManager.Observer
    // ═══════════════════════════════════════════════════════════════════════════

    override fun onStatus(connectionId: String, status: String, connected: Boolean) {
        if (connectionId == this.connectionId && !connected) { Toast.makeText(this, "桌面已断开", Toast.LENGTH_SHORT).show(); returnToSessionList() }
    }

    override fun onSessionsChanged(connectionId: String) {
        if (connectionId != this.connectionId) return
        val updated = ConnectionManager.sessionById(this.connectionId, sessionId)
        if (updated == null) { Toast.makeText(this, "桌面窗口已关闭", Toast.LENGTH_SHORT).show(); returnToSessionList() }
        else { session = updated; refreshInputState() }
    }

    override fun onMessage(connectionId: String, sessionId: String, msg: ChatMessage) {
        if (connectionId == this.connectionId && sessionId == this.sessionId) { adapter.notifyItemInserted(adapter.itemCount - 1); scrollToBottom() }
    }

    // endregion
    // ═══════════════════════════════════════════════════════════════════════════
    // MARK: - Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    private val Int.dp: Int get() = (this * resources.displayMetrics.density).toInt()
    private val Float.dpF: Float get() = this * resources.displayMetrics.density
}
