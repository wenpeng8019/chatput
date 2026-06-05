package com.chatput.app

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

/** 聊天界面：按住按钮说话，松开发送识别文本到桌面 */
class ChatActivity : AppCompatActivity(), ConnectionManager.Observer {

    companion object {
        const val EXTRA_CONNECTION_ID = "connection_id"
        const val EXTRA_SESSION_ID = "session_id"
        private const val CLEAR_HOLD_DURATION_MS = 750L
        private const val HINT_DEFAULT = "按住说话"
        private const val HINT_ENGLISH = "请说英文"
        private const val TALK_TAP_MAX_MS = 180L

        // 光标拖动手势
        private const val CURSOR_ACTIVATION_DP = 28f   // 语音按钮需明显拖出一段距离才切到光标模式
        private const val CURSOR_STEP_DP = 24f         // 水平棘轮步长：每拖动这么远移动一个字符
        private const val CURSOR_SWIPE_TRIGGER_DP = 32f // 上下需继续划出这段距离，松手后才切一行
        private const val CURSOR_VERTICAL_BIAS = 1.8f  // 垂直需明显大于水平才锁定上下行，避免误触发换行
        private const val CURSOR_CONTINUOUS_DP = 96f   // 连续移动阈值的回退默认值；运行时按「麦克风中心→侧按钮中心」的实际距离重算（见 cursorContinuousPx）
        private const val CURSOR_REPEAT_MAX_MS = 200L  // 连续移动最慢速度
        private const val CURSOR_REPEAT_MIN_MS = 40L   // 连续移动最快速度

        private const val COMPOSER_LIFT_DP = 56f       // 呼出文字输入时语音框被"拉高"渐出的位移
    }

    private lateinit var binding: ActivityChatBinding
    private lateinit var adapter: MessageAdapter
    private lateinit var speech: SpeechHelper
    private var screenCurtain: ScreenCurtainController? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var session: Session? = null
    private var connectionId: String = ""
    private var sessionId: String = ""
    private var lastInputHeightPx = 0

    private var clearAnimator: ValueAnimator? = null
    private var clearCancelled = false
    private var clearCompleted = false
    private var enterAnimator: ValueAnimator? = null
    private var enterCancelled = false
    private var enterCompleted = false

    private var inputVisible = false   // 文字输入栏是否展开
    private var englishModeAvailable = false

    // 光标拖动手势状态
    private var gestureStartX = 0f
    private var gestureStartY = 0f
    private var inCursorMode = false
    private var cursorVertical = false   // true=垂直（上下行），false=水平（左右字）
    private var cursorContinuous = false // 是否处于连续触发（驱动方向提示的点裂变 + chevron 外移）
    private var cursorDelta = 0f         // 锁定轴上相对起点的偏移（px，棘轮逐字用，进入光标模式后重定基线）
    private var cursorOriginX = 0f       // 麦克风中心的屏幕 X（连续触发判定的绝对基准，不重定基线）
    private var cursorAbsX = 0f          // 当前手指的屏幕 X
    private var lastStepIndex = 0        // 已经发出的离散步数（含正负）
    private var cursorRepeating = false
    private var talkDownAt = 0L
    private var talkMode = SpeechHelper.Mode.DEFAULT
    private var isTalkingActive = false  // 正在录音（驱动方向提示整体淡出）
    private var lastTalkTapUpAt = 0L
    private var lastTalkTapX = 0f
    private var lastTalkTapY = 0f
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
                if (cursorContinuous) {
                    cursorContinuous = false
                    refreshDirectionHints()
                }
            }
        }
    }

    private val hintResetRunnable = Runnable {
        binding.hint.text = currentIdleHint()
    }

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
        if (session == null) {
            finish()
            return
        }

        binding.appTitle.text = session!!.app.ifBlank { "ChatPUT" }
        binding.subtitle.text = session!!.device.ifBlank { session!!.title.ifBlank { "当前窗口" } }

        adapter = MessageAdapter(
            session!!.messages,
            onResend = { anchor, position -> resendMessage(anchor, position) },
            onLongPress = { anchor, position -> showMessageActions(anchor, position) }
        )
        binding.list.layoutManager = LinearLayoutManager(this).apply { stackFromEnd = true }
        binding.list.adapter = adapter
        scrollToBottom()

        speech = SpeechHelper(this)
        englishModeAvailable = SpeechHelper.hasEnglishModel(this)

        bindVoiceButton()
        bindBackspaceButton()
        bindEnterButton()
        bindDragHandle()
        bindTextInput()
        binding.btnHeaderMenu.setOnClickListener { showHeaderMenu(it) }

        setupScreenCurtain()

        onBackPressedDispatcher.addCallback(this, object : OnBackPressedCallback(true) {
            override fun handleOnBackPressed() {
                if (inputVisible) {
                    hideTextInput()
                } else {
                    isEnabled = false
                    onBackPressedDispatcher.onBackPressed()
                }
            }
        })
    }

    private fun bindVoiceButton() {
        val viewConfig = android.view.ViewConfiguration.get(this)
        val dragActivationPx = kotlin.math.max(
            viewConfig.scaledTouchSlop * 2f,
            CURSOR_ACTIVATION_DP.dpF
        )
        val tapTimeoutMs = android.view.ViewConfiguration.getDoubleTapTimeout().toLong()
        val doubleTapSlopPx = viewConfig.scaledDoubleTapSlop.toFloat()
        binding.btnTalk.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    val isDoubleTap =
                        englishModeAvailable &&
                        event.eventTime - lastTalkTapUpAt <= tapTimeoutMs &&
                            kotlin.math.hypot(
                                event.rawX - lastTalkTapX,
                                event.rawY - lastTalkTapY
                            ) <= doubleTapSlopPx
                    gestureStartX = event.rawX
                    gestureStartY = event.rawY
                    talkDownAt = event.eventTime
                    talkMode = if (isDoubleTap) SpeechHelper.Mode.ENGLISH else SpeechHelper.Mode.DEFAULT
                    inCursorMode = false
                    cursorDelta = 0f
                    cursorOriginX = talkCenterX()   // 连续触发的绝对基准：麦克风中心
                    cursorAbsX = event.rawX
                    lastStepIndex = 0
                    cursorRepeating = false
                    startTalking(v, talkMode)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    cursorAbsX = event.rawX
                    if (!inCursorMode) {
                        val dx = event.rawX - gestureStartX
                        val dy = event.rawY - gestureStartY
                        if (kotlin.math.hypot(dx, dy) > dragActivationPx) {
                            // 按起手主方向锁定轴；垂直需明显占优才算上下行，否则默认水平移光标
                            cursorVertical =
                                kotlin.math.abs(dy) > kotlin.math.abs(dx) * CURSOR_VERTICAL_BIAS
                            enterCursorMode()
                            gestureStartX = event.rawX   // 以进入光标模式的位置为基准
                            gestureStartY = event.rawY
                        }
                    }
                    if (inCursorMode) {
                        if (cursorVertical) {
                            updateCursorSwipe(event.rawY - gestureStartY)
                        } else {
                            updateCursorDrag(event.rawX - gestureStartX)
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (inCursorMode) {
                        endCursorMode(v)
                    } else {
                        val pressDuration = event.eventTime - talkDownAt
                        val quickTap = pressDuration <= TALK_TAP_MAX_MS
                        if (quickTap) {
                            cancelTalking(v)
                            if (talkMode == SpeechHelper.Mode.DEFAULT && englishModeAvailable) {
                                lastTalkTapUpAt = event.eventTime
                                lastTalkTapX = event.rawX
                                lastTalkTapY = event.rawY
                                showTransientHint("再按一次进入英文输入")
                            } else {
                                lastTalkTapUpAt = 0L
                                binding.hint.text = HINT_DEFAULT
                            }
                        } else {
                            lastTalkTapUpAt = 0L
                            stopTalking(v)
                        }
                    }
                    true
                }
                else -> false
            }
        }
    }

    /** 同步方向提示装饰到当前状态。 */
    private fun refreshDirectionHints() {
        binding.directionHints.setState(
            talking = isTalkingActive,
            cursorMode = inCursorMode,
            vertical = cursorVertical,
            continuous = cursorContinuous
        )
    }

    /** 从说话切换到光标控制：丢弃录音，进入拖动模式（不震动，交给逐字步进）。 */
    private fun enterCursorMode() {
        mainHandler.removeCallbacks(hintResetRunnable)
        inCursorMode = true
        lastStepIndex = 0
        cursorRepeating = false
        cursorContinuous = false
        isTalkingActive = false
        speech.cancel()
        setOrbActive(false)
        refreshDirectionHints()
        binding.hint.text = if (cursorVertical) "↑ 上滑松手切行 ↓" else "← 拖动移动光标 →"
    }

    /** 当前锁定轴与方向对应的动作。positive=右/下。 */
    private fun cursorActionFor(positive: Boolean): String = when {
        cursorVertical && positive -> "cursorDown"
        cursorVertical -> "cursorUp"
        positive -> "cursorRight"
        else -> "cursorLeft"
    }

    /**
     * 水平棘轮式拖动：每跨过一个步长移动一个字符并锁定，反向才回退；
     * 仅当偏移超过连续阈值（约到按钮处）才开始自动连续移动。
     */
    private fun updateCursorDrag(delta: Float) {
        cursorDelta = delta
        val stepPx = CURSOR_STEP_DP.dpF
        val stepIndex = Math.round(delta / stepPx)
        if (stepIndex != lastStepIndex) {
            val positive = stepIndex > lastStepIndex
            val count = kotlin.math.abs(stepIndex - lastStepIndex)
            repeat(count) {
                sendAction(cursorActionFor(positive))
                cursorStepHaptic()   // 移动一个字符的触感反馈
            }
            lastStepIndex = stepIndex
        }

        if (kotlin.math.abs(cursorContinuousDelta()) >= cursorContinuousPx()) {
            if (!cursorRepeating) {
                cursorRepeating = true
                mainHandler.postDelayed(cursorRepeatRunnable, cursorRepeatInterval())
            }
            if (!cursorContinuous) {
                cursorContinuous = true
                refreshDirectionHints()
            }
        } else {
            cursorRepeating = false
            mainHandler.removeCallbacks(cursorRepeatRunnable)
            if (cursorContinuous) {
                cursorContinuous = false
                refreshDirectionHints()
            }
        }
    }

    /** 上下行 swipe：滑动中只预判方向，松手时最多移动一行。 */
    private fun updateCursorSwipe(delta: Float) {
        cursorDelta = delta
        val trigger = CURSOR_SWIPE_TRIGGER_DP.dpF
        if (kotlin.math.abs(delta) >= trigger) {
            binding.hint.text = if (delta > 0) "↓ 松手切到下一行" else "↑ 松手切到上一行"
        } else {
            binding.hint.text = "↑ 上滑松手切行 ↓"
        }
    }

    /** 连续移动间隔：偏移越过连续阈值后越远越快。 */
    private fun cursorRepeatInterval(): Long {
        val travel = kotlin.math.abs(cursorContinuousDelta())
        val start = cursorContinuousPx()
        val full = start + CURSOR_STEP_DP.dpF * 8f
        val t = ((travel - start) / (full - start)).coerceIn(0f, 1f)
        return (CURSOR_REPEAT_MAX_MS - (CURSOR_REPEAT_MAX_MS - CURSOR_REPEAT_MIN_MS) * t).toLong()
    }

    /**
     * 连续触发的绝对偏移：以麦克风中心为基准（不随进入光标模式重定基线），
     * 确保「滑到侧按钮中心」才切连续，而不是多偏移一个激活距离。
     */
    private fun cursorContinuousDelta(): Float = cursorAbsX - cursorOriginX

    /** 麦克风按钮中心的屏幕 X。 */
    private fun talkCenterX(): Float {
        val loc = IntArray(2)
        binding.btnTalk.getLocationOnScreen(loc)
        return loc[0] + binding.btnTalk.width / 2f
    }

    /**
     * 连续光标移动的触发阈值：麦克风中心 → 侧按钮（退格）中心的水平距离，
     * 根据按钮实际布局位置计算，随设备宽度自适应。布局未就绪时回退到默认值。
     */
    private fun cursorContinuousPx(): Float {
        val talk = binding.btnTalk
        val side = binding.btnBackspace
        if (talk.width == 0 || side.width == 0) return CURSOR_CONTINUOUS_DP.dpF
        val talkCenter = talk.x + talk.width / 2f
        val sideCenter = side.x + side.width / 2f
        return kotlin.math.abs(talkCenter - sideCenter)
    }

    private fun endCursorMode(v: View) {
        mainHandler.removeCallbacks(hintResetRunnable)
        if (cursorVertical && kotlin.math.abs(cursorDelta) >= CURSOR_SWIPE_TRIGGER_DP.dpF) {
            sendAction(cursorActionFor(cursorDelta > 0))
            cursorStepHaptic()
        }
        inCursorMode = false
        cursorRepeating = false
        cursorContinuous = false
        cursorDelta = 0f
        mainHandler.removeCallbacks(cursorRepeatRunnable)
        refreshDirectionHints()
        v.isPressed = false
        binding.hint.text = currentIdleHint()
    }

    /** 移动一步的触感：水平=单击，垂直（换行）=双击以示区别。 */
    private fun cursorStepHaptic() {
        v_haptic()
        if (cursorVertical) mainHandler.postDelayed({ v_haptic() }, 55)
    }

    private fun v_haptic() {
        binding.btnTalk.performHapticFeedback(
            HapticFeedbackConstants.KEYBOARD_TAP,
            HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING
        )
    }

    private fun bindBackspaceButton() {
        binding.btnBackspace.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    v.isPressed = true
                    startClearHold()
                }
                MotionEvent.ACTION_UP -> {
                    v.isPressed = false
                    val cleared = stopClearHold()
                    if (!cleared) sendAction("backspace")
                }
                MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    stopClearHold()
                }
            }
            true
        }
    }

    private fun bindEnterButton() {
        binding.btnEnter.setOnTouchListener { v, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    v.isPressed = true
                    startEnterHold()
                }
                MotionEvent.ACTION_UP -> {
                    v.isPressed = false
                    val entered = stopEnterHold()
                    if (!entered) sendAction("shiftEnter")
                }
                MotionEvent.ACTION_CANCEL -> {
                    v.isPressed = false
                    stopEnterHold()
                }
            }
            true
        }
    }

    /** 把"向上拖拽呼出文字输入"的手势绑定到全宽拖拽感应层。 */
    private fun bindDragHandle() {
        binding.dragHandle.setOnTouchListener(dragGestureListener())
    }

    /** 生成一个独立状态的拖拽手势监听器。 */
    private fun dragGestureListener(): View.OnTouchListener {
        val slop = android.view.ViewConfiguration.get(this).scaledTouchSlop
        val pullMax = 96f.dpF
        var startY = 0f
        var startX = 0f
        var triggered = false
        var blocked = false
        return View.OnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    blocked = isInTalkButtonSwipeZone(event.rawX)
                    startY = event.rawY
                    startX = event.rawX
                    triggered = false
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (blocked) return@OnTouchListener true
                    if (!triggered) {
                        val pulled = startY - event.rawY            // 向上为正
                        if (pulled > 0) applyComposerPull(pulled / pullMax)
                        // 拉过阈值即提交，呼出输入法
                        if (pulled > pullMax * 0.55f) {
                            triggered = true
                            showTextInput()
                        }
                    }
                    true
                }
                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    if (blocked) {
                        blocked = false
                        return@OnTouchListener true
                    }
                    if (!triggered) {
                        val pulled = startY - event.rawY
                        if (pulled < slop) {
                            // 轻点：仅当落在语音框可视范围内才呼出，避免点到两侧/上方留白触发
                            if (isWithinComposer(startX, startY)) showTextInput()
                        } else {
                            snapComposerBack()         // 未过阈值，回弹复原
                        }
                    }
                    true
                }
                else -> true
            }
        }
    }

    private fun isInTalkButtonSwipeZone(rawX: Float): Boolean {
        val location = IntArray(2)
        binding.composerCard.getLocationOnScreen(location)
        val centerX = if (binding.composerCard.width > 0) {
            location[0] + binding.composerCard.width / 2f
        } else {
            resources.displayMetrics.widthPixels / 2f
        }
        return kotlin.math.abs(rawX - centerX) <= 70f.dpF
    }

    /** 触点是否落在语音框（composer_card）的实际可视范围内。 */
    private fun isWithinComposer(rawX: Float, rawY: Float): Boolean {
        val loc = IntArray(2)
        binding.composerCard.getLocationOnScreen(loc)
        val left = loc[0]
        val top = loc[1]
        val right = left + binding.composerCard.width
        val bottom = top + binding.composerCard.height
        return rawX >= left && rawX <= right && rawY >= top && rawY <= bottom
    }

    /** 拖拽过程中：语音交互框随手指被"拉高"并渐出（progress 0→1）。 */
    private fun applyComposerPull(progress: Float) {
        val p = progress.coerceIn(0f, 1f)
        val ty = -COMPOSER_LIFT_DP.dpF * p
        val a = 1f - p
        binding.composerCard.translationY = ty
        binding.composerCard.alpha = a
        binding.hint.translationY = ty
        binding.hint.alpha = a
        binding.grabDecor.translationY = ty
        binding.grabDecor.alpha = a
    }

    /** 拉动未过阈值：语音交互框回落复原。 */
    private fun snapComposerBack() {
        listOf(binding.composerCard, binding.hint, binding.grabDecor).forEach {
            it.animate().translationY(0f).alpha(1f).setDuration(200)
                .setInterpolator(android.view.animation.DecelerateInterpolator()).start()
        }
    }

    private fun bindTextInput() {
        binding.btnTextMic.setOnClickListener { hideTextInput() }
        binding.btnSend.setOnClickListener { sendTypedText() }
        binding.inputText.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_SEND) {
                sendTypedText()
                true
            } else {
                false
            }
        }
        bindTextInputSwipeDown()
    }

    /**
     * 文本输入面板下滑手势 — 向下拖动超阈值切回语音面板。
     * 手势挂在 EditText 自身上，return true 接管事件流才能持续收到 MOVE；
     * 同时手动调 [View.onTouchEvent] 把事件转发给 EditText，保证打字不受影响。
     */
    private fun bindTextInputSwipeDown() {
        val swipeMin = ViewConfiguration.get(this).scaledTouchSlop.toFloat()
        var startY = 0f
        var tracking = false
        binding.inputText.setOnTouchListener { view, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    startY = event.rawY
                    tracking = false
                    view.onTouchEvent(event)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!tracking && event.rawY - startY > swipeMin) {
                        tracking = true
                    }
                    if (tracking) {
                        true  // 滑动中，不让 EditText 处理
                    } else {
                        view.onTouchEvent(event)
                        true
                    }
                }
                MotionEvent.ACTION_UP -> {
                    if (tracking && event.rawY - startY > 28f.dpF) {
                        hideTextInput()
                        tracking = false
                        true
                    } else {
                        tracking = false
                        view.onTouchEvent(event)
                        true
                    }
                }
                MotionEvent.ACTION_CANCEL -> {
                    tracking = false
                    view.onTouchEvent(event)
                    true
                }
                else -> { view.onTouchEvent(event); true }
            }
        }
    }

    private fun imm(): InputMethodManager =
        getSystemService(Context.INPUT_METHOD_SERVICE) as InputMethodManager

    /** 呼出文字输入栏并弹出系统键盘。语音交互框拉高渐出，输入栏渐入。 */
    private fun showTextInput() {
        if (inputVisible) return
        inputVisible = true
        val lift = -COMPOSER_LIFT_DP.dpF
        val deco = android.view.animation.DecelerateInterpolator()

        setDragZonesEnabled(false)
        binding.composerCard.animate()
            .translationY(lift).alpha(0f).setDuration(220).setInterpolator(deco)
            .withEndAction { binding.composerCard.visibility = View.INVISIBLE }.start()
        binding.hint.animate()
            .translationY(lift).alpha(0f).setDuration(220).setInterpolator(deco)
            .withEndAction { binding.hint.visibility = View.INVISIBLE }.start()
        binding.grabDecor.animate()
            .translationY(lift).alpha(0f).setDuration(180).setInterpolator(deco)
            .withEndAction { binding.grabDecor.visibility = View.INVISIBLE }.start()

        binding.textInputCard.apply {
            alpha = 0f
            visibility = View.VISIBLE
            animate().alpha(1f).setDuration(220).setStartDelay(60).start()
        }
        binding.inputText.requestFocus()
        imm().showSoftInput(binding.inputText, InputMethodManager.SHOW_IMPLICIT)
        binding.composerCard.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
    }

    /** 收起文字输入栏与键盘。输入栏渐出，语音交互框渐入回落。 */
    private fun hideTextInput() {
        if (!inputVisible) return
        inputVisible = false
        imm().hideSoftInputFromWindow(binding.inputText.windowToken, 0)
        binding.inputText.clearFocus()
        val deco = android.view.animation.DecelerateInterpolator()

        binding.textInputCard.animate()
            .alpha(0f).setDuration(150)
            .withEndAction {
                binding.textInputCard.visibility = View.GONE
            }.start()

        binding.composerCard.visibility = View.VISIBLE
        binding.hint.visibility = View.VISIBLE
        binding.grabDecor.visibility = View.VISIBLE
        listOf(binding.composerCard, binding.hint, binding.grabDecor).forEach {
            it.animate().translationY(0f).alpha(1f).setDuration(240)
                .setInterpolator(deco).setStartDelay(40).start()
        }
        setDragZonesEnabled(true)
    }

    /** 启用 / 停用拖拽感应层（输入栏展开时停用，避免误触）。 */
    private fun setDragZonesEnabled(enabled: Boolean) {
        binding.dragHandle.isEnabled = enabled
        binding.dragHandle.isClickable = enabled
    }

    /** 发送输入框中的文字（记入历史），保持输入栏打开以便连续输入。 */
    private fun sendTypedText() {
        val text = binding.inputText.text?.toString()?.trim().orEmpty()
        if (text.isBlank()) return
        if (!isInputAvailable()) {
            if (!ConnectionManager.isConnected) {
                Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            }
            return
        }
        session?.let { ConnectionManager.sendText(it, text) }
        binding.inputText.text?.clear()
    }

    /** 桌面端输入控件是否可用（窗口打开但 input 可能被 AI 菜单等暂时遮住）。 */
    private fun isInputAvailable(): Boolean {
        return session?.inputAvailable != false && ConnectionManager.isConnected
    }

    private fun sendAction(action: String) {
        if (!isInputAvailable()) {
            if (!ConnectionManager.isConnected) {
                Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            }
            return
        }
        session?.let { ConnectionManager.sendAction(it, action) }
    }

    override fun onResume() {
        super.onResume()
        ConnectionManager.addObserver(this)
        // 页面恢复时主动检查连接是否仍然有效（断连可能发生在暂停期间）。
        val currentSession = ConnectionManager.sessionById(connectionId, sessionId)
        if (currentSession == null || !ConnectionManager.isConnected) {
            returnToSessionList()
            return
        }
        session = currentSession
    }

    override fun onPause() {
        super.onPause()
        ConnectionManager.removeObserver(this)
    }

    override fun onDestroy() {
        super.onDestroy()
        mainHandler.removeCallbacksAndMessages(null)
        clearAnimator?.cancel()
        enterAnimator?.cancel()
        screenCurtain?.release()
        speech.destroy()
    }

    private fun startTalking(v: View, mode: SpeechHelper.Mode) {
        mainHandler.removeCallbacks(hintResetRunnable)
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Toast.makeText(this, "请先授予录音权限", Toast.LENGTH_SHORT).show()
            return
        }
        if (!isInputAvailable()) {
            if (!ConnectionManager.isConnected) {
                Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            }
            return
        }
        v.isPressed = true
        setOrbActive(true)
        isTalkingActive = true
        refreshDirectionHints()
        binding.hint.text = if (mode == SpeechHelper.Mode.ENGLISH) HINT_ENGLISH else "正在听…"
        speech.start(object : SpeechHelper.Callback {
            override fun onPartial(text: String) {
                binding.hint.text = text
            }

            override fun onResult(text: String) {
                binding.hint.text = HINT_DEFAULT
                if (text.isNotBlank()) {
                    session?.let {
                        ConnectionManager.sendText(it, text)
                    }
                }
            }

            override fun onError(message: String) {
                binding.hint.text = HINT_DEFAULT
                Toast.makeText(this@ChatActivity, message, Toast.LENGTH_SHORT).show()
            }
        }, mode)
    }

    private fun stopTalking(v: View) {
        mainHandler.removeCallbacks(hintResetRunnable)
        v.isPressed = false
        setOrbActive(false)
        isTalkingActive = false
        refreshDirectionHints()
        speech.stop()
    }

    private fun cancelTalking(v: View) {
        mainHandler.removeCallbacks(hintResetRunnable)
        v.isPressed = false
        setOrbActive(false)
        isTalkingActive = false
        refreshDirectionHints()
        speech.cancel()
    }

    private fun setOrbActive(active: Boolean) {
        val scale = if (active) 0.93f else 1f
        binding.btnTalk.animate()
            .scaleX(scale)
            .scaleY(scale)
            .setDuration(130)
            .start()
        binding.orbHalo.animate()
            .alpha(if (active) 1f else 0f)
            .scaleX(if (active) 1.12f else 0.85f)
            .scaleY(if (active) 1.12f else 0.85f)
            .setDuration(180)
            .start()
    }

    /** 长按回删触发清空：填充进度环，满 2s 后执行清空。 */
    private fun startClearHold() {
        clearCancelled = false
        clearCompleted = false
        binding.clearProgress.progress = 0
        binding.clearProgress.visibility = View.VISIBLE
        clearAnimator?.cancel()
        clearAnimator = ValueAnimator.ofInt(0, 100).apply {
            duration = CLEAR_HOLD_DURATION_MS
            addUpdateListener { binding.clearProgress.progress = it.animatedValue as Int }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationCancel(animation: Animator) {
                    clearCancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    binding.clearProgress.visibility = View.GONE
                    if (clearCancelled) return
                    clearCompleted = true
                    binding.btnBackspace.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                    sendAction("clear")
                    showTransientHint("已清空")
                }
            })
            start()
        }
    }

    /** 结束长按。返回是否已经触发了清空（用于区分短按回删）。 */
    private fun stopClearHold(): Boolean {
        clearAnimator?.cancel()
        clearAnimator = null
        binding.clearProgress.visibility = View.GONE
        return clearCompleted
    }

    private fun startEnterHold() {
        enterCancelled = false
        enterCompleted = false
        binding.enterProgress.progress = 0
        binding.enterProgress.visibility = View.VISIBLE
        enterAnimator?.cancel()
        enterAnimator = ValueAnimator.ofInt(0, 100).apply {
            duration = CLEAR_HOLD_DURATION_MS
            addUpdateListener { binding.enterProgress.progress = it.animatedValue as Int }
            addListener(object : AnimatorListenerAdapter() {
                override fun onAnimationCancel(animation: Animator) {
                    enterCancelled = true
                }

                override fun onAnimationEnd(animation: Animator) {
                    binding.enterProgress.visibility = View.GONE
                    if (enterCancelled) return
                    enterCompleted = true
                    binding.btnEnter.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
                    sendAction("enter")
                }
            })
            start()
        }
    }

    private fun stopEnterHold(): Boolean {
        enterAnimator?.cancel()
        enterAnimator = null
        binding.enterProgress.visibility = View.GONE
        return enterCompleted
    }

    private fun showTransientHint(text: String) {
        binding.hint.text = text
        mainHandler.removeCallbacks(hintResetRunnable)
        mainHandler.postDelayed(hintResetRunnable, 1_200)
    }

    private fun currentIdleHint(): String {
        return if (binding.btnTalk.isPressed && !inCursorMode && talkMode == SpeechHelper.Mode.ENGLISH) {
            HINT_ENGLISH
        } else {
            HINT_DEFAULT
        }
    }

    /** 顶栏菜单：进入远程窗口画面。 */
    private fun showHeaderMenu(anchor: View) {
        anchor.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        val content = layoutInflater.inflate(R.layout.popup_header_actions, binding.root, false)
        val popup = PopupWindow(
            content,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            true
        )
        popup.isOutsideTouchable = true
        popup.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        content.findViewById<View>(R.id.action_view_screen).setOnClickListener {
            popup.dismiss()
            openScreenView()
        }

        content.measure(
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        )
        val xOffset = anchor.width - content.measuredWidth + 14.dp
        popup.showAsDropDown(anchor, xOffset, 8.dp)
    }

    /** 把当前 IME 高度同步给幕布控制器，让其自行计算键盘上推量。 */
    private fun updateScreenCurtainLift(imeBottom: Int) {
        val inputH = binding.textInputCard.height.takeIf { it > 0 } ?: lastInputHeightPx
        if (inputH > 0) lastInputHeightPx = inputH
        screenCurtain?.updateKeyboardLift(binding.root.height, imeBottom, inputH)
    }

    private fun openScreenView() {
        if (!ConnectionManager.isConnected) {
            Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            return
        }
        screenCurtain?.open()
    }

    /** 初始化「下拉幕布」视频面板：内嵌控制器 + 手势/动画控制器。 */
    private fun setupScreenCurtain() {
        val s = session ?: return
        val panel = ScreenPanelController(
            renderer = binding.screenRenderer,
            minimap = binding.minimap,
            statusLabel = binding.screenStatus,
            cover = binding.screenCover,
        )
        panel.init(DesktopConnection.eglBaseContext())
        panel.bind(s.connectionId, s)

        val curtain = ScreenCurtainController(
            panel = binding.screenPanel,
            shadow = binding.screenShadow,
            grabHandle = binding.screenGrab,
            headerDragHost = binding.chatHeader,
            controller = panel,
        )
        screenCurtain = curtain
        // 幕布底部热区：打开后在 hint 文案区上滑可收起整块面板（关闭视频）。
        curtain.bindCollapseZone(binding.screenCollapseZone)
    }

    private fun showEnterActions(anchor: View, belowAnchor: Boolean = false) {
        anchor.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        val content = layoutInflater.inflate(R.layout.popup_enter_actions, binding.root, false)
        val popup = PopupWindow(
            content,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            true
        )
        popup.isOutsideTouchable = true
        popup.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        content.findViewById<View>(R.id.action_select_all).setOnClickListener {
            sendAction("selectAll")
            popup.dismiss()
        }
        content.findViewById<View>(R.id.action_clear).setOnClickListener {
            sendAction("clear")
            showTransientHint("已清空")
            popup.dismiss()
        }

        content.measure(
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        )
        val xOffset = if (belowAnchor) anchor.width - content.measuredWidth + 14.dp
        else (anchor.width - content.measuredWidth) / 2
        val yOffset = if (belowAnchor) 8.dp else -(anchor.height + content.measuredHeight - 8.dp)
        popup.showAsDropDown(anchor, xOffset, yOffset)
    }

    /** 双击历史气泡：重新发送（不新增历史项），并弹出"已发送"气泡。 */
    private fun resendMessage(anchor: View, position: Int) {
        val msg = session?.messages?.getOrNull(position) ?: return
        if (!isInputAvailable()) {
            if (!ConnectionManager.isConnected) {
                Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            }
            return
        }
        anchor.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        session?.let { ConnectionManager.resendText(it, msg.text) }
        showSentBalloon(anchor, "已发送")
    }

    /** 长按历史气泡：弹出重新发送 / 删除菜单。 */
    private fun showMessageActions(anchor: View, position: Int) {
        anchor.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        val content = layoutInflater.inflate(R.layout.popup_message_actions, binding.root, false)
        val popup = PopupWindow(
            content,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            true
        )
        popup.isOutsideTouchable = true
        popup.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        content.findViewById<View>(R.id.action_resend).setOnClickListener {
            popup.dismiss()
            resendMessage(anchor, position)
        }
        content.findViewById<View>(R.id.action_delete).setOnClickListener {
            popup.dismiss()
            deleteMessage(position)
        }

        content.measure(
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        )
        val xOffset = (anchor.width - content.measuredWidth) / 2
        val yOffset = -(anchor.height + content.measuredHeight - 8.dp)
        popup.showAsDropDown(anchor, xOffset, yOffset)
    }

    /** 删除一条历史记录。 */
    private fun deleteMessage(position: Int) {
        val messages = session?.messages ?: return
        if (position !in messages.indices) return
        messages.removeAt(position)
        adapter.notifyItemRemoved(position)
    }

    /** 在锚点上方弹出气泡提示，短暂停留后向上漂浮并淡出消失。 */
    private fun showSentBalloon(anchor: View, text: String) {
        val container = layoutInflater.inflate(R.layout.balloon_sent, binding.root, false) as ViewGroup
        val balloon = container.findViewById<TextView>(R.id.balloon_text)
        balloon.text = text
        val popup = PopupWindow(
            container,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            false
        )
        popup.isClippingEnabled = false
        popup.setBackgroundDrawable(ColorDrawable(Color.TRANSPARENT))

        container.measure(
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED),
            View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED)
        )
        // 容器顶部有 28dp 余量（供上漂），文字位于容器底部。
        // 让文字本身与气泡垂直居中对齐：先扣掉顶部余量，再按文字高度居中。
        val textHeight = balloon.measuredHeight
        val xOffset = -(container.measuredWidth + 10.dp)
        val yOffset = -(anchor.height / 2 + (container.measuredHeight - textHeight) + textHeight / 2)
        popup.showAsDropDown(anchor, xOffset, yOffset)

        balloon.alpha = 0f
        balloon.animate()
            .alpha(1f)
            .setDuration(140)
            .withEndAction {
                // 停留后向上漂浮 + 渐隐；容器顶部留有余量，上漂不会被截断。
                balloon.animate()
                    .alpha(0f)
                    .translationY((-22f).dpF)
                    .setStartDelay(540)
                    .setDuration(460)
                    .withEndAction { if (!isFinishing) popup.dismiss() }
                    .start()
            }
            .start()
    }

    private fun scrollToBottom() {
        if (adapter.itemCount > 0) binding.list.scrollToPosition(adapter.itemCount - 1)
    }

    private fun applyEdgeToEdgeInsets() {
        val headerTop = 18.dp
        val listTop = 12.dp
        val listBottom = 8.dp
        val composerBottom = 2.dp
        val hintBottom = 8.dp

        ViewCompat.setOnApplyWindowInsetsListener(binding.root) { _, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            val tappable = insets.getInsets(WindowInsetsCompat.Type.tappableElement())
            val gestures = insets.getInsets(WindowInsetsCompat.Type.systemGestures())

            // 键盘收起时自动还原：隐藏文字输入栏，恢复把手
            val imeVisible = insets.isVisible(WindowInsetsCompat.Type.ime())
            if (inputVisible && !imeVisible) {
                hideTextInput()
            }
            // 文字输入栏吸附在输入法面板的上边缘
            val imeBottom = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
            binding.textInputCard.updateLayoutParams<ViewGroup.MarginLayoutParams> {
                bottomMargin = imeBottom
            }

            val visualBottomInset = when {
                tappable.bottom > 0 -> tappable.bottom
                gestures.bottom > 0 -> gestures.bottom / 2
                else -> systemBars.bottom / 2
            }

            binding.chatHeader.updateLayoutParams<ViewGroup.MarginLayoutParams> {
                topMargin = headerTop + systemBars.top
            }
            binding.list.updatePadding(
                top = listTop,
                bottom = listBottom
            )
            binding.hint.updateLayoutParams<ViewGroup.MarginLayoutParams> {
                bottomMargin = hintBottom
            }
            binding.composerCard.updateLayoutParams<ViewGroup.MarginLayoutParams> {
                bottomMargin = composerBottom + visualBottomInset
            }

            updateScreenCurtainLift(imeBottom)

            insets
        }

        // 逐帧驱动文字输入栏跟随键盘升降；视频面板底边已约束钉在输入栏顶部，
        // 故每帧 relayout 时面板与输入栏同帧上移，完全同步、无延迟。
        ViewCompat.setWindowInsetsAnimationCallback(
            binding.root,
            object : androidx.core.view.WindowInsetsAnimationCompat.Callback(
                androidx.core.view.WindowInsetsAnimationCompat.Callback.DISPATCH_MODE_CONTINUE_ON_SUBTREE
            ) {
                override fun onProgress(
                    insets: WindowInsetsCompat,
                    runningAnimations: List<androidx.core.view.WindowInsetsAnimationCompat>
                ): WindowInsetsCompat {
                    val imeBottom = insets.getInsets(WindowInsetsCompat.Type.ime()).bottom
                    binding.textInputCard.updateLayoutParams<ViewGroup.MarginLayoutParams> {
                        bottomMargin = imeBottom
                    }
                    // 键盘弹起时把整块视频面板向上平移让出空间（尺寸不变，窗帘式上推）。
                    updateScreenCurtainLift(imeBottom)
                    return insets
                }
            }
        )
    }

    private fun applySystemBarAppearance() {
        val nightMode = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK
        val lightBars = nightMode != Configuration.UI_MODE_NIGHT_YES
        WindowCompat.getInsetsController(window, window.decorView)?.let { controller ->
            controller.isAppearanceLightStatusBars = lightBars
            controller.isAppearanceLightNavigationBars = lightBars
        }
    }

    private fun returnToSessionList() {
        startActivity(
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
            }
        )
        finish()
    }

    // --- ConnectionManager.Observer ---
    override fun onStatus(connectionId: String, status: String, connected: Boolean) {
        if (connectionId == this.connectionId && !connected) {
            Toast.makeText(this, "桌面已断开", Toast.LENGTH_SHORT).show()
            returnToSessionList()
        }
    }

    override fun onSessionsChanged(connectionId: String) {
        if (connectionId != this.connectionId) return
        val updated = ConnectionManager.sessionById(this.connectionId, sessionId)
        if (updated == null) {
            Toast.makeText(this, "桌面窗口已关闭", Toast.LENGTH_SHORT).show()
            returnToSessionList()
        } else {
            session = updated
            refreshInputState()
        }
    }

    /** 根据 session.inputAvailable 启用/禁用输入控件。 */
    private fun refreshInputState() {
        val available = session?.inputAvailable != false
        val alpha = if (available) 1f else 0.35f
        binding.btnTalk.alpha = alpha
        binding.btnTalk.isEnabled = available
        binding.btnBackspace.alpha = alpha
        binding.btnBackspace.isEnabled = available
        binding.btnEnter.alpha = alpha
        binding.btnEnter.isEnabled = available
        binding.inputText.isEnabled = available
        binding.btnSend.isEnabled = available
        if (!available) {
            binding.hint.text = "输入暂时不可用…"
        }
    }

    override fun onMessage(connectionId: String, sessionId: String, msg: ChatMessage) {
        if (connectionId == this.connectionId && sessionId == this.sessionId) {
            adapter.notifyItemInserted(adapter.itemCount - 1)
            scrollToBottom()
        }
    }

    private val Int.dp: Int
        get() = (this * resources.displayMetrics.density).toInt()

    private val Float.dpF: Float
        get() = this * resources.displayMetrics.density
}
