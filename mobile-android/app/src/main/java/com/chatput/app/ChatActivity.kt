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
        private const val CURSOR_CONTINUOUS_DP = 96f   // 超过此偏移（约到按钮位置）才进入连续移动
        private const val CURSOR_REPEAT_MAX_MS = 200L  // 连续移动最慢速度
        private const val CURSOR_REPEAT_MIN_MS = 40L   // 连续移动最快速度

        private const val COMPOSER_LIFT_DP = 56f       // 呼出文字输入时语音框被"拉高"渐出的位移
    }

    private lateinit var binding: ActivityChatBinding
    private lateinit var adapter: MessageAdapter
    private lateinit var speech: SpeechHelper
    private val mainHandler = Handler(Looper.getMainLooper())
    private var session: Session? = null

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
    private var cursorDelta = 0f         // 锁定轴上相对起点的偏移（px）
    private var lastStepIndex = 0        // 已经发出的离散步数（含正负）
    private var cursorRepeating = false
    private var talkDownAt = 0L
    private var talkMode = SpeechHelper.Mode.DEFAULT
    private var lastTalkTapUpAt = 0L
    private var lastTalkTapX = 0f
    private var lastTalkTapY = 0f
    private val cursorRepeatRunnable = object : Runnable {
        override fun run() {
            if (!inCursorMode) return
            if (kotlin.math.abs(cursorDelta) >= CURSOR_CONTINUOUS_DP.dpF) {
                sendAction(cursorActionFor(cursorDelta > 0))
                v_haptic()
                mainHandler.postDelayed(this, cursorRepeatInterval())
            } else {
                cursorRepeating = false
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

        val id = intent.getStringExtra(EXTRA_SESSION_ID)
        session = ConnectionManager.sessionById(id ?: "")
        if (session == null) {
            finish()
            return
        }

        binding.appTitle.text = session!!.app.ifBlank { "聊入" }
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
        binding.btnHeaderMenu.setOnClickListener { showEnterActions(it, belowAnchor = true) }

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
                    lastStepIndex = 0
                    cursorRepeating = false
                    startTalking(v, talkMode)
                    true
                }
                MotionEvent.ACTION_MOVE -> {
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

    /** 从说话切换到光标控制：丢弃录音，进入拖动模式（不震动，交给逐字步进）。 */
    private fun enterCursorMode() {
        mainHandler.removeCallbacks(hintResetRunnable)
        inCursorMode = true
        lastStepIndex = 0
        cursorRepeating = false
        speech.cancel()
        setOrbActive(false)
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

        if (kotlin.math.abs(delta) >= CURSOR_CONTINUOUS_DP.dpF) {
            if (!cursorRepeating) {
                cursorRepeating = true
                mainHandler.postDelayed(cursorRepeatRunnable, cursorRepeatInterval())
            }
        } else {
            cursorRepeating = false
            mainHandler.removeCallbacks(cursorRepeatRunnable)
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
        val travel = kotlin.math.abs(cursorDelta)
        val start = CURSOR_CONTINUOUS_DP.dpF
        val full = start + CURSOR_STEP_DP.dpF * 8f
        val t = ((travel - start) / (full - start)).coerceIn(0f, 1f)
        return (CURSOR_REPEAT_MAX_MS - (CURSOR_REPEAT_MAX_MS - CURSOR_REPEAT_MIN_MS) * t).toLong()
    }

    private fun endCursorMode(v: View) {
        mainHandler.removeCallbacks(hintResetRunnable)
        if (cursorVertical && kotlin.math.abs(cursorDelta) >= CURSOR_SWIPE_TRIGGER_DP.dpF) {
            sendAction(cursorActionFor(cursorDelta > 0))
            cursorStepHaptic()
        }
        inCursorMode = false
        cursorRepeating = false
        cursorDelta = 0f
        mainHandler.removeCallbacks(cursorRepeatRunnable)
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
        var triggered = false
        var blocked = false
        return View.OnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    blocked = isInTalkButtonSwipeZone(event.rawX)
                    startY = event.rawY
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
                            showTextInput()           // 轻点直接呼出
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
        return kotlin.math.abs(rawX - centerX) <= 52f.dpF
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
        binding.btnSend.setOnClickListener { sendTypedText() }
        binding.inputText.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_SEND) {
                sendTypedText()
                true
            } else {
                false
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
        if (!ConnectionManager.isConnected) {
            Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            return
        }
        session?.let { ConnectionManager.sendText(it, text) }
        binding.inputText.text?.clear()
    }

    private fun sendAction(action: String) {
        if (!ConnectionManager.isConnected) {
            Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            return
        }
        session?.let { ConnectionManager.sendAction(it, action) }
    }

    override fun onResume() {
        super.onResume()
        ConnectionManager.addObserver(this)
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
        if (!ConnectionManager.isConnected) {
            Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
            return
        }
        v.isPressed = true
        setOrbActive(true)
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
        speech.stop()
    }

    private fun cancelTalking(v: View) {
        mainHandler.removeCallbacks(hintResetRunnable)
        v.isPressed = false
        setOrbActive(false)
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
        if (!ConnectionManager.isConnected) {
            Toast.makeText(this, "未连接到桌面端", Toast.LENGTH_SHORT).show()
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

            insets
        }
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
    override fun onStatus(status: String, connected: Boolean) {
        if (!connected) {
            Toast.makeText(this, "桌面已断开", Toast.LENGTH_SHORT).show()
            returnToSessionList()
        }
    }

    override fun onSessionsChanged() {
        val currentId = session?.id ?: return
        val updated = ConnectionManager.sessionById(currentId)
        if (updated == null) {
            Toast.makeText(this, "桌面窗口已关闭", Toast.LENGTH_SHORT).show()
            returnToSessionList()
        } else {
            session = updated
        }
    }

    override fun onMessage(sessionId: String, msg: ChatMessage) {
        if (sessionId == session?.id) {
            adapter.notifyItemInserted(adapter.itemCount - 1)
            scrollToBottom()
        }
    }

    private val Int.dp: Int
        get() = (this * resources.displayMetrics.density).toInt()

    private val Float.dpF: Float
        get() = this * resources.displayMetrics.density
}
