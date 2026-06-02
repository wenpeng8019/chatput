package com.chatput.app

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import com.k2fsa.sherpa.onnx.OfflineModelConfig
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

    interface Callback {
        fun onPartial(text: String)
        fun onResult(text: String)
        fun onError(message: String)
    }

    companion object {
        private const val MODEL_DIR = "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17"
        private const val SAMPLE_RATE = 16000

        // 识别器较重，全 App 共享一个实例
        @Volatile
        private var recognizer: OfflineRecognizer? = null
        private val initExecutor = Executors.newSingleThreadExecutor()

        /** 在后台预初始化识别器（首次加载模型较慢） */
        fun preload(context: Context) {
            if (recognizer != null) return
            val app = context.applicationContext
            initExecutor.execute { ensureRecognizer(app) }
        }

        @Synchronized
        private fun ensureRecognizer(context: Context): OfflineRecognizer? {
            if (recognizer != null) return recognizer
            val config = OfflineRecognizerConfig(
                featConfig = getFeatureConfig(sampleRate = SAMPLE_RATE, featureDim = 80),
                modelConfig = OfflineModelConfig(
                    senseVoice = OfflineSenseVoiceModelConfig(
                        model = "$MODEL_DIR/model.int8.onnx",
                        useInverseTextNormalization = true
                    ),
                    tokens = "$MODEL_DIR/tokens.txt",
                    numThreads = 2,
                    debug = false
                )
            )
            recognizer = OfflineRecognizer(
                assetManager = context.assets,
                config = config
            )
            return recognizer
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var audioRecord: AudioRecord? = null
    @Volatile
    private var recording = false
    private val samples = ArrayList<Float>()
    private var callback: Callback? = null

    fun isAvailable(): Boolean = true

    @SuppressLint("MissingPermission")
    fun start(callback: Callback) {
        this.callback = callback
        synchronized(samples) { samples.clear() }

        if (ensureRecognizer(context.applicationContext) == null) {
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

        thread(name = "asr-decode") {
            try {
                val rec = recognizer ?: return@thread postError("识别器未初始化")
                val stream = rec.createStream()
                stream.acceptWaveform(data, SAMPLE_RATE)
                rec.decode(stream)
                val text = rec.getResult(stream).text.trim()
                stream.release()
                main.post {
                    if (text.isBlank()) callback?.onError("没有识别到内容")
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
