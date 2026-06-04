import AVFoundation
import Foundation
import Speech

@MainActor
final class SpeechRecognizer: ObservableObject {
    enum Mode {
        case standard
        case english
    }

    var onPartial: ((String) -> Void)?
    var onResult: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var lastText = ""
    private var receivedAudio = false
    private var sessionConfigured = false

    static var englishModeAvailable: Bool { SFSpeechRecognizer(locale: Locale(identifier: "en-US")) != nil }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { _ in }
        AVAudioSession.sharedInstance().requestRecordPermission { _ in }
    }

    func prepare() {
        guard !sessionConfigured else { return }
        // 音频会话激活与引擎启动是重操作，放到后台线程，避免阻塞主线程（否则会卡住页面导航）。
        Task.detached(priority: .userInitiated) { [audioEngine] in
            guard SpeechRecognizer.activateSession() else { return }
            SpeechRecognizer.startEngine(audioEngine)
            await MainActor.run { [weak self] in self?.sessionConfigured = true }
        }
    }

    func teardown() {
        cancel()
        let wasConfigured = sessionConfigured
        sessionConfigured = false
        // 停止引擎与停用会话同样放到后台，避免在页面退出时阻塞主线程。
        Task.detached(priority: .utility) { [audioEngine] in
            if audioEngine.isRunning { audioEngine.stop() }
            if wasConfigured {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    private func configureSessionIfNeeded() {
        guard !sessionConfigured else { return }
        if SpeechRecognizer.activateSession() {
            sessionConfigured = true
        }
        // 否则保留未配置状态，下次再试
    }

    /// 激活录音用的音频会话。线程安全，可在后台线程调用。
    nonisolated private static func activateSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            return true
        } catch {
            return false
        }
    }

    /// 启动音频引擎。线程安全，可在后台线程调用。
    nonisolated private static func startEngine(_ audioEngine: AVAudioEngine) {
        guard !audioEngine.isRunning else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.prepare()
        try? audioEngine.start()
    }

    private func startEngineIfNeeded() {
        guard sessionConfigured else { return }
        SpeechRecognizer.startEngine(audioEngine)
    }

    func start(mode: Mode) {
        cancel()
        lastText = ""
        receivedAudio = false

        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            break
        case .notDetermined:
            onError?("请先授予语音识别权限")
            requestPermissions()
            return
        default:
            onError?("语音识别权限未开启")
            return
        }

        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            break
        case .undetermined:
            onError?("请允许麦克风权限后再按一次")
            session.requestRecordPermission { _ in }
            return
        case .denied:
            onError?("麦克风权限未开启")
            return
        @unknown default:
            onError?("麦克风权限不可用")
            return
        }

        let locale = mode == .english ? Locale(identifier: "en-US") : Locale(identifier: "zh-CN")
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            onError?("语音识别暂不可用")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self, weak request] result, error in
            Task { @MainActor in
                guard let self, let request, self.request === request else { return }
                if let text = result?.bestTranscription.formattedString, !text.isEmpty {
                    self.lastText = text
                    self.onPartial?(text)
                }
                if result?.isFinal == true {
                    self.finishAudio()
                    self.onResult?(self.lastText)
                } else if let error {
                    self.finishAudio()
                    self.onError?(self.message(for: error))
                }
            }
        }

        do {
            configureSessionIfNeeded()
            startEngineIfNeeded()
            let session = AVAudioSession.sharedInstance()
            let input = audioEngine.inputNode
            guard let format = recordingFormat(for: input, session: session) else {
                finishAudio()
                onError?("当前环境没有可用麦克风，请使用文字输入")
                return
            }

            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self, weak request] buffer, _ in
                if buffer.frameLength > 0 {
                    Task { @MainActor in self?.receivedAudio = true }
                }
                request?.append(buffer)
            }
            if !audioEngine.isRunning {
                audioEngine.prepare()
                try audioEngine.start()
            }
        } catch {
            task?.cancel()
            task = nil
            self.request = nil
            onError?(error.localizedDescription)
            return
        }
    }

    private func message(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == "kAFAssistantErrorDomain" {
            return noSpeechMessage()
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("no speech") || desc.contains("corrupt") || desc.contains("retry") || desc.contains("could not be completed") || desc.contains("kafassistant") {
            return noSpeechMessage()
        }
        return error.localizedDescription
    }

    private func noSpeechMessage() -> String {
        if receivedAudio {
            return "没听清，请靠近麦克风再说一次"
        }
        #if targetEnvironment(simulator)
        return "模拟器没有收到声音：请在 Simulator 菜单 Device → Microphone 勾选麦克风，并确认 macOS 已允许 Simulator 使用麦克风"
        #else
        return "没有收到麦克风声音，请检查麦克风权限"
        #endif
    }

    private func recordingFormat(for input: AVAudioInputNode, session: AVAudioSession) -> AVAudioFormat? {
        let outputFormat = input.outputFormat(forBus: 0)
        if isUsable(outputFormat) { return outputFormat }

        if session.sampleRate > 0, session.inputNumberOfChannels > 0 {
            return AVAudioFormat(standardFormatWithSampleRate: session.sampleRate, channels: AVAudioChannelCount(session.inputNumberOfChannels))
        }

        return nil
    }

    private func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    func stop() {
        request?.endAudio()
        finishAudio(keepTask: true)
        if !lastText.isEmpty { onResult?(lastText) }
    }

    func cancel() {
        task?.cancel()
        finishAudio()
    }

    private func finishAudio(keepTask: Bool = false) {
        audioEngine.inputNode.removeTap(onBus: 0)
        request = nil
        if !keepTask { task = nil }
    }
}
