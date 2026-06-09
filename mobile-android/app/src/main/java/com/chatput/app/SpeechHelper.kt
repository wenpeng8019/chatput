package com.chatput.app

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import com.k2fsa.sherpa.onnx.OfflineModelConfig
import com.k2fsa.sherpa.onnx.OfflineParaformerModelConfig
import com.k2fsa.sherpa.onnx.OfflineRecognizer
import com.k2fsa.sherpa.onnx.OfflineRecognizerConfig
import com.k2fsa.sherpa.onnx.OfflineSenseVoiceModelConfig
import com.k2fsa.sherpa.onnx.getFeatureConfig
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * 基于 sherpa-onnx + SenseVoice 的离线语音识别（按住说话）。
 * 完全离线，不依赖系统语音服务，国行手机可用。
 *
 * 交互：start() 开始录音（按住），stop() 结束录音并离线识别整段（松开）。
 */
class SpeechHelper(private val context: Context) {

    enum class Mode {
        DEFAULT,
        ENGLISH
    }

    interface Callback {
        fun onPartial(text: String)
        fun onResult(text: String)
        fun onError(message: String)
    }

    companion object {
        private const val DEFAULT_MODEL_DIR = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
        private const val ENGLISH_MODEL_DIR = "sherpa-onnx-paraformer-en-2024-03-09"
        private const val SAMPLE_RATE = 16000

        // 识别器较重，全 App 共享实例，按模式懒加载
        @Volatile
        private var defaultRecognizer: OfflineRecognizer? = null
        @Volatile
        private var englishRecognizer: OfflineRecognizer? = null
        private val initExecutor = Executors.newSingleThreadExecutor()

        /** 在后台预初始化默认识别器（首次加载模型较慢） */
        fun preload(context: Context) {
            if (defaultRecognizer != null) return
            val app = context.applicationContext
            initExecutor.execute { ensureRecognizer(app, Mode.DEFAULT) }
        }

        fun hasEnglishModel(context: Context): Boolean {
            if (!BuildConfig.ENABLE_ENGLISH_MODEL) return false
            return try {
                val assets = context.assets
                assets.openFd("$ENGLISH_MODEL_DIR/model.int8.onnx").close()
                assets.openFd("$ENGLISH_MODEL_DIR/tokens.txt").close()
                true
            } catch (_: Exception) {
                false
            }
        }

        @Synchronized
        private fun ensureRecognizer(context: Context, mode: Mode): OfflineRecognizer? {
            if (mode == Mode.ENGLISH && !hasEnglishModel(context)) return null
            when (mode) {
                Mode.DEFAULT -> defaultRecognizer?.let { return it }
                Mode.ENGLISH -> englishRecognizer?.let { return it }
            }

            val config = when (mode) {
                Mode.DEFAULT -> OfflineRecognizerConfig(
                    featConfig = getFeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
                    modelConfig = OfflineModelConfig(
                        senseVoice = OfflineSenseVoiceModelConfig(
                            model = "$DEFAULT_MODEL_DIR/model.int8.onnx",
                            useInverseTextNormalization = true
                        ),
                        tokens = "$DEFAULT_MODEL_DIR/tokens.txt",
                        numThreads = 2,
                        debug = false
                    )
                )
                Mode.ENGLISH -> OfflineRecognizerConfig(
                    featConfig = getFeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
                    modelConfig = OfflineModelConfig(
                        paraformer = OfflineParaformerModelConfig(
                            model = "$ENGLISH_MODEL_DIR/model.int8.onnx"
                        ),
                        tokens = "$ENGLISH_MODEL_DIR/tokens.txt",
                        numThreads = 2,
                        debug = false
                    )
                )
            }

            val recognizer = OfflineRecognizer(
                assetManager = context.assets,
                config = config
            )
            when (mode) {
                Mode.DEFAULT -> defaultRecognizer = recognizer
                Mode.ENGLISH -> englishRecognizer = recognizer
            }
            return recognizer
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var audioRecord: AudioRecord? = null
    @Volatile
    private var recording = false
    private val samples = ArrayList<Float>()
    private var callback: Callback? = null
    private var activeMode = Mode.DEFAULT

    fun isAvailable(): Boolean = true

    @SuppressLint("MissingPermission")
    fun start(callback: Callback, mode: Mode = Mode.DEFAULT) {
        this.callback = callback
        this.activeMode = mode
        synchronized(samples) { samples.clear() }

        if (ensureRecognizer(context.applicationContext, mode) == null) {
            postError("识别模型尚未就绪，请稍候")
            return
        }

        val minBuf = AudioRecord.getMinBufferSize(
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT
        )
        val bufferSize = maxOf(minBuf, SAMPLE_RATE) // 至少 1s 缓冲
        val record = AudioRecord(
            MediaRecorder.AudioSource.MIC,
            SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
            bufferSize
        )
        if (record.state != AudioRecord.STATE_INITIALIZED) {
            record.release()
            postError("无法启动录音")
            return
        }
        audioRecord = record
        recording = true
        record.startRecording()

        thread(name = "asr-capture") {
            val buf = ShortArray(SAMPLE_RATE / 10) // 100ms
            while (recording) {
                val n = record.read(buf, 0, buf.size)
                if (n > 0) {
                    synchronized(samples) {
                        for (i in 0 until n) {
                            samples.add(buf[i] / 32768.0f)
                        }
                    }
                }
            }
        }
    }

    /** 松开按钮：停止录音并离线识别整段 */
    fun stop() {
        if (!recording) return
        recording = false
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        audioRecord?.release()
        audioRecord = null

        val data: FloatArray
        synchronized(samples) {
            data = FloatArray(samples.size) { samples[it] }
        }

        if (data.size < SAMPLE_RATE / 5) { // 不足 0.2s
            postError("说话时间太短")
            return
        }

        // 前置能量检测：过滤静音/极低噪音，避免送入模型产生随机输出
        val rms = kotlin.math.sqrt(data.sumOf { (it * it).toDouble() } / data.size)
        if (rms < 1e-4) {
            postError("没有识别到内容")
            return
        }

        thread(name = "asr-decode") {
            try {
                val rec = ensureRecognizer(context.applicationContext, activeMode)
                    ?: return@thread postError("识别器未初始化")
                val stream = rec.createStream()
                stream.acceptWaveform(data, SAMPLE_RATE)
                rec.decode(stream)
                val result = rec.getResult(stream)
                val text = result.text.trim()
                val event = result.event
                stream.release()
                main.post {
                    // SenseVoice 内建静音检测：返回 <nospeech> 事件表示无有效语音
                    if (event.contains("<nospeech>") || text.isBlank()) callback?.onError("没有识别到内容")
                    else callback?.onResult(text)
                }
            } catch (e: Exception) {
                postError("识别失败: ${e.message}")
            }
        }
    }

    fun destroy() {
        recording = false
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        audioRecord?.release()
        audioRecord = null
        callback = null
    }

    /** 取消当前录音并丢弃结果（不回调 onResult/onError）。 */
    fun cancel() {
        if (!recording) return
        recording = false
        try {
            audioRecord?.stop()
        } catch (_: Exception) {
        }
        audioRecord?.release()
        audioRecord = null
        synchronized(samples) { samples.clear() }
    }

    private fun postError(msg: String) {
        main.post { callback?.onError(msg) }
    }
}
