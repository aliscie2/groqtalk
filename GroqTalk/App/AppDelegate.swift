import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Services
    let api = GroqAPIClient()
    let recorder = AudioRecorder()
    let player = AudioPlayer()
    let hotkeys = HotkeyService()
    let history = HistoryManager()
    let usage = UsageTracker()
    var statusBar: StatusBarController!
    private var kokoroProcess: Process?
    private var whisperProcess: Process?
    private var mlxSTTProcess: Process?

    // MARK: - State
    enum AppState { case idle, recording, processing, speaking }
    var appState: AppState = .idle {
        didSet { statusBar?.updateIcon(appState) }
    }

    var enhanceText = false
    var sttMode: ConfigManager.STTMode = ConfigManager.defaultSTTMode
    var currentVoice = ConfigManager.ttsVoice
    var playbackRate: Float = 1.25

    private var sttTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationHelper.requestPermission()
        AccessibilityChecker.checkAndPrompt()
        statusBar = StatusBarController(delegate: self)
        setupHotkeys()

        if ConfigManager.shared.apiKey.isEmpty {
            Log.info("No API key — prompting user")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.statusBar.promptAPIKey()
            }
        } else {
            warmConnection()
        }

        startKokoroServer()
        if sttMode == .localSmall { startWhisperServer() }
        else if sttMode == .localLarge { startMLXSTTServer() }
        Log.info("GroqTalk started — Fn (Record) | Ctrl+Option (Speak) | RAM: \(ConfigManager.systemRAMGB)GB | STT: \(sttMode.rawValue)")
    }

    // MARK: - Kokoro TTS Server

    private func startKokoroServer() {
        let script = ConfigManager.configDir + "/start_tts.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            Log.error("[KOKORO] start_tts.sh not found")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            kokoroProcess = proc
            Log.info("[KOKORO] local TTS server launched (PID \(proc.processIdentifier))")
        } catch {
            Log.error("[KOKORO] failed to start: \(error)")
        }
    }

    // MARK: - Local Whisper STT Server

    func startWhisperServer() {
        // Stop existing server first
        if let proc = whisperProcess, proc.isRunning {
            proc.terminate()
            whisperProcess = nil
        }

        guard let entry = ConfigManager.sttModels.first(where: { $0.mode == sttMode }) else { return }
        let modelPath = entry.path
        guard FileManager.default.fileExists(atPath: modelPath) else {
            Log.error("[WHISPER] model not found at \(modelPath)")
            NotificationHelper.sendStatus("\u{274C} Whisper model not found")
            return
        }

        let whisperBin = "/opt/homebrew/bin/whisper-server"
        guard FileManager.default.fileExists(atPath: whisperBin) else {
            Log.error("[WHISPER] whisper-server not found")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: whisperBin)
        proc.arguments = [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", "8724",
            "--language", "en",
            "--no-timestamps",
            "--flash-attn",
            "-bs", "1"
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            whisperProcess = proc
            Log.info("[WHISPER] local STT server launched (PID \(proc.processIdentifier))")
        } catch {
            Log.error("[WHISPER] failed to start: \(error)")
        }
    }

    func stopWhisperServer() {
        whisperProcess?.terminate()
        whisperProcess = nil
        Log.info("[WHISPER] server stopped")
    }

    // MARK: - MLX Whisper STT Server (Large)

    func startMLXSTTServer() {
        guard mlxSTTProcess == nil || !mlxSTTProcess!.isRunning else {
            Log.info("[MLX-STT] already running")
            return
        }

        let script = ConfigManager.configDir + "/start_stt.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            Log.error("[MLX-STT] start_stt.sh not found")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            mlxSTTProcess = proc
            Log.info("[MLX-STT] local large STT server launched (PID \(proc.processIdentifier))")
        } catch {
            Log.error("[MLX-STT] failed to start: \(error)")
        }
    }

    func stopMLXSTTServer() {
        mlxSTTProcess?.terminate()
        mlxSTTProcess = nil
        Log.info("[MLX-STT] server stopped")
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        hotkeys.install()
        hotkeys.installModifierHotkeys(
            fnAction: { [weak self] in self?.toggleRecording() },
            ctrlOptAction: { [weak self] in self?.speakSelected() }
        )
    }

    // MARK: - Warmup

    private func warmConnection() {
        Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.api.listModels()
                Log.info("[WARM] Groq connection pre-warmed")
            } catch {
                Log.error("[WARM] warmup failed: \(error)")
            }
        }
    }

    // MARK: - Recording (STT)

    func toggleRecording() {
        if appState == .recording { stopRecording() }
        else if appState == .idle { startRecording() }
    }

    func startRecording() {
        guard appState == .idle else { return }
        do {
            try recorder.start()
            appState = .recording
            NotificationHelper.sendStatus("\u{1F534} Recording... Press Fn to stop")
            startLiveTranscription()
        } catch {
            Log.error("[REC] failed: \(error)")
            appState = .idle
        }
    }

    func stopRecording() {
        guard appState == .recording else { return }
        liveTask?.cancel()
        let buffers = recorder.stop()
        appState = .processing
        statusBar.setStopVisible(true)

        sttTask = Task { [weak self] in
            guard let self else { return }
            await TranscriptionService.process(
                buffers: buffers, api: api, enhance: enhanceText,
                history: history, usage: usage, sttMode: sttMode
            )
            await MainActor.run {
                self.appState = .idle
                self.statusBar.setStopVisible(false)
                self.statusBar.refreshHistory()
                self.statusBar.refreshCost()
            }
        }
    }

    private func startLiveTranscription() {
        liveTask = Task { [weak self] in
            guard let self else { return }
            await TranscriptionService.liveLoop(recorder: recorder, api: api, usage: usage, sttMode: sttMode)
        }
    }

    // MARK: - TTS

    func speakSelected() {
        // Always stop any ongoing playback first
        ttsTask?.cancel()
        player.stop()

        if appState == .speaking {
            appState = .idle
            statusBar.setStopVisible(false)
            NotificationHelper.clearStatus()
            Log.info("[TTS] stopped by user")
            return
        }
        guard appState == .idle else { return }
        appState = .speaking
        statusBar.setStopVisible(true)

        ttsTask = Task { [weak self] in
            guard let self else { return }
            await SpeechService.speak(
                api: api, player: player, voice: currentVoice,
                rate: playbackRate, history: history, usage: usage
            )
            await MainActor.run {
                self.appState = .idle
                self.statusBar.setStopVisible(false)
                self.statusBar.refreshHistory()
                self.statusBar.refreshCost()
            }
        }
    }

    // MARK: - Replay

    func replayRecording() {
        guard let entry = history.load().last, let path = entry.ttsWavPath else { return }
        replayEntry(path: path)
    }

    func replayEntry(path: String) {
        ttsTask?.cancel()
        player.stop()
        appState = .speaking
        statusBar.setStopVisible(true)

        ttsTask = Task { [weak self] in
            guard let self else { return }
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                await player.play(data: data, rate: playbackRate)
            }
            await MainActor.run {
                self.appState = .idle
                self.statusBar.setStopVisible(false)
            }
        }
    }

    func reuseText(_ text: String) {
        ClipboardService.write(text)
        NotificationHelper.send(title: "GroqTalk", message: "Copied to clipboard")
    }

    // MARK: - Retry pending recording

    func retryPending(timestamp: String) {
        // Use detached task so stopAll() doesn't cancel it
        Task.detached { [weak self] in
            guard let self else { return }
            await MainActor.run { self.appState = .processing }

            await TranscriptionService.retryPending(
                timestamp: timestamp, api: self.api, enhance: self.enhanceText,
                history: self.history, usage: self.usage, sttMode: self.sttMode
            )

            await MainActor.run {
                self.appState = .idle
                self.statusBar.refreshHistory()
                self.statusBar.refreshCost()
            }
        }
    }

    // MARK: - Stop

    func stopAll() {
        sttTask?.cancel()
        ttsTask?.cancel()
        liveTask?.cancel()
        player.stop()
        if appState == .recording { _ = recorder.stop() }
        appState = .idle
        statusBar.setStopVisible(false)
        NotificationHelper.clearStatus()
        Log.info("[STOP] all stopped")
    }

    // MARK: - API Key

    func reloadAPIKey() {
        ConfigManager.shared.apiKey = ConfigManager.loadAPIKey()
        ConfigManager.shared.openAIKey = ConfigManager.loadOpenAIKey()
        Log.info("[APP] API keys reloaded")
        warmConnection()
    }

    // MARK: - Quit

    func quit() {
        hotkeys.unregisterAll()
        recorder.stop()
        player.stop()
        kokoroProcess?.terminate()
        whisperProcess?.terminate()
        mlxSTTProcess?.terminate()
        NSApplication.shared.terminate(nil)
    }
}
