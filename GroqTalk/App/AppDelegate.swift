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
    var appState: AppState = .idle { didSet { statusBar?.updateIcon(appState) } }
    var sttMode: ConfigManager.STTMode = ConfigManager.defaultSTTMode
    var ttsEngine: ConfigManager.TTSEngine = ConfigManager.defaultTTSEngine
    var currentVoice = ConfigManager.ttsEngineEntry(ConfigManager.defaultTTSEngine).defaultVoice
    var playbackRate: Float = 1.25
    var currentTTSModel: String { ConfigManager.ttsEngineEntry(ttsEngine).model }
    private var sttTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?

    // MARK: - Lifecycle
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationHelper.requestPermission()
        AccessibilityChecker.checkAndPrompt()
        statusBar = StatusBarController(delegate: self)
        setupHotkeys()
        // Any NSSecureTextField focus anywhere silently gags CGEventTap; the
        // monitor surfaces a lock icon so the cause is visible in under a sec.
        SecureInputMonitor.shared.start { [weak self] in self?.statusBar.setSecureInputWarning($0) }
        SoundCue.prepare()
        TTSDialog.shared.onChunkTap = { [weak self] idx in self?.jumpToChunk(idx) }
        TTSDialog.shared.onWordTap = { [weak self] idx, t in self?.jumpToWord(chunk: idx, time: t) }
        TTSDialog.shared.onPauseToggle = { [weak self] in
            guard let self else { return }
            self.player.togglePause()
            TTSDialog.shared.setPaused(self.player.paused)
        }
        TTSDialog.shared.onClose = { [weak self] in
            self?.ttsTask?.cancel(); self?.player.stop()
            self?.appState = .idle; self?.statusBar.setStopVisible(false)
            TTSDialog.shared.close()
        }
        ModelLifecycle.kokoroStart  = { [weak self] in self?.startKokoroServer() }
        ModelLifecycle.kokoroStop   = { [weak self] in self?.stopKokoroServer() }
        ModelLifecycle.whisperStart = { [weak self] in self?.startWhisperServer() }
        ModelLifecycle.whisperStop  = { [weak self] in self?.stopWhisperServer() }
        startKokoroServer()
        ModelLifecycle.markKokoroStarted()
        if sttMode == .localSmall {
            startWhisperServer(); ModelLifecycle.markWhisperStarted()
        } else if sttMode == .localLarge {
            startMLXSTTServer()
        }
        Log.info("GroqTalk started — Fn (Record) | Ctrl+Option (Speak) | RAM: \(ConfigManager.systemRAMGB)GB | STT: \(sttMode.rawValue) | idleUnload: \(ConfigManager.idleUnloadSeconds)s")
    }

    // MARK: - Server spawn (table-driven)
    /// Everything server-specific lives in `ServerSpec`; all shared plumbing
    /// (stdout redirect, termination handler, circuit-breaker auto-restart)
    /// lives in `run(_:)`.
    private struct ServerSpec {
        let name: String
        let port: UInt16
        let logFile: String      // "" → /dev/null
        let shouldRestart: () -> Bool
        let launcher: () -> Process?
        let getProcess: () -> Process?
        let setProcess: (Process?) -> Void
    }
    private var restartWindows: [String: Date] = [:]
    private var restartCounts: [String: Int] = [:]
    private let maxRestartsPerWindow = 3
    private let restartWindowSec: TimeInterval = 30

    private func run(_ spec: ServerSpec) {
        guard let proc = spec.launcher() else { return }
        if !spec.logFile.isEmpty, let fh = Self.truncatingLogHandle(at: spec.logFile) {
            proc.standardOutput = fh; proc.standardError = fh
        } else {
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
        }
        proc.terminationHandler = { [weak self] p in
            Log.error("[\(spec.name)] server exited (code=\(p.terminationStatus))")
            DispatchQueue.main.async {
                guard let self,
                      spec.getProcess()?.processIdentifier == p.processIdentifier else { return }
                spec.setProcess(nil)
                guard spec.shouldRestart() else { return }
                let now = Date()
                if now.timeIntervalSince(self.restartWindows[spec.name] ?? .distantPast) > self.restartWindowSec {
                    self.restartWindows[spec.name] = now
                    self.restartCounts[spec.name] = 0
                }
                self.restartCounts[spec.name, default: 0] += 1
                let count = self.restartCounts[spec.name] ?? 0
                if count > self.maxRestartsPerWindow {
                    Log.error("[\(spec.name)] \(count) crashes in \(Int(self.restartWindowSec))s — giving up auto-restart")
                    NotificationHelper.sendStatus("\u{274C} \(spec.name) server keeps crashing")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    guard let self, spec.getProcess() == nil else { return }
                    Log.info("[\(spec.name)] auto-restarting after crash (attempt \(count))")
                    self.run(spec)
                }
            }
        }
        do {
            try proc.run()
            spec.setProcess(proc)
            Log.info("[\(spec.name)] launched (PID \(proc.processIdentifier))")
        } catch {
            Log.error("[\(spec.name)] failed to start: \(error)")
        }
    }

    private static func truncatingLogHandle(at path: String) -> FileHandle? {
        let url = URL(fileURLWithPath: path)
        try? "".write(to: url, atomically: true, encoding: .utf8)
        return try? FileHandle(forWritingTo: url)
    }

    // MARK: - Port helpers
    /// SIGKILL (not SIGTERM — mid-model-load servers ignore SIGTERM for tens
    /// of seconds, causing EADDRINUSE on the next spawn), then wait for port.
    private func killExisting(pattern: String, port: UInt16) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-9", "-f", pattern]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run(); task.waitUntilExit()
        let deadline = Date().addingTimeInterval(4.0)
        while Date() < deadline {
            if canBind(port: port) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        Log.error("[PORT] \(port) still busy — next spawn may fail")
    }

    private func canBind(port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        defer { close(sock) }
        var reuse: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return ok == 0
    }

    // MARK: - Kokoro TTS Server (8723)
    func startKokoroServer() {
        run(ServerSpec(
            name: "KOKORO", port: 8723,
            logFile: ConfigManager.configDir + "/tts_server.log",
            shouldRestart: { true },
            launcher: { [weak self] in
                guard let self else { return nil }
                let script = ConfigManager.configDir + "/start_tts.sh"
                guard FileManager.default.fileExists(atPath: script) else {
                    Log.error("[KOKORO] start_tts.sh not found"); return nil
                }
                self.killExisting(pattern: "mlx_audio.server", port: 8723)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = [script]
                // launchd strips PATH; the script needs /opt/homebrew visible.
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                proc.environment = env
                // mlx_audio.server writes logs/ in CWD; bundle CWD is EROFS.
                proc.currentDirectoryURL = URL(fileURLWithPath: ConfigManager.configDir)
                return proc
            },
            getProcess: { [weak self] in self?.kokoroProcess },
            setProcess: { [weak self] p in self?.kokoroProcess = p }
        ))
    }

    /// Restart mlx_audio.server to evict cached models (RAM relief, 16 GB).
    func restartKokoroServer() {
        Log.info("[KOKORO] restarting to evict cached models")
        kokoroProcess?.terminate(); kokoroProcess = nil
        startKokoroServer()
    }

    func stopKokoroServer() {
        kokoroProcess?.terminate(); kokoroProcess = nil
        // Belt-and-braces: kill orphans too, mlx_audio sometimes forks.
        killExisting(pattern: "mlx_audio.server", port: 8723)
        Log.info("[KOKORO] server stopped (idle unload)")
    }

    // MARK: - Local Whisper STT Server (small, 8724)
    func startWhisperServer() {
        if let p = whisperProcess, p.isRunning { p.terminate(); whisperProcess = nil }
        run(ServerSpec(
            name: "WHISPER", port: 8724, logFile: "",
            shouldRestart: { false },
            launcher: { [weak self] in
                guard let self,
                      let entry = ConfigManager.sttModels.first(where: { $0.mode == self.sttMode })
                else { return nil }
                let modelPath = entry.path
                guard FileManager.default.fileExists(atPath: modelPath) else {
                    Log.error("[WHISPER] model not found at \(modelPath)")
                    NotificationHelper.sendStatus("\u{274C} Whisper model not found"); return nil
                }
                let bin = "/opt/homebrew/bin/whisper-server"
                guard FileManager.default.fileExists(atPath: bin) else {
                    Log.error("[WHISPER] whisper-server not found"); return nil
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: bin)
                // --dtw + --max-len 1 + --split-on-word + --word-thold give
                // per-word segments for karaoke highlighting in TTSDialog.
                proc.arguments = [
                    "--model", modelPath, "--host", "127.0.0.1", "--port", "8724",
                    "--language", "en", "--no-timestamps", "--flash-attn", "-bs", "1",
                    "--dtw", self.dtwPreset(forModelPath: modelPath),
                    "--max-len", "1", "--split-on-word", "--word-thold", "0.01"
                ]
                return proc
            },
            getProcess: { [weak self] in self?.whisperProcess },
            setProcess: { [weak self] p in self?.whisperProcess = p }
        ))
    }

    private func dtwPreset(forModelPath path: String) -> String {
        let n = (path as NSString).lastPathComponent.lowercased()
        if n.contains("large-v3") { return "large.v3" }
        if n.contains("large-v2") { return "large.v2" }
        if n.contains("large-v1") { return "large.v1" }
        if n.contains("large")    { return "large.v3" }
        if n.contains("medium.en") || n.contains("medium-en") { return "medium.en" }
        if n.contains("medium")    { return "medium" }
        if n.contains("small.en") || n.contains("small-en") { return "small.en" }
        if n.contains("small")    { return "small" }
        if n.contains("base.en")  || n.contains("base-en")  { return "base.en" }
        if n.contains("base")     { return "base" }
        if n.contains("tiny.en")  || n.contains("tiny-en")  { return "tiny.en" }
        if n.contains("tiny")     { return "tiny" }
        return "small.en"
    }

    func stopWhisperServer() {
        whisperProcess?.terminate(); whisperProcess = nil
        Log.info("[WHISPER] server stopped")
    }

    // MARK: - MLX Whisper STT Server (large, 8725)
    func startMLXSTTServer() {
        guard mlxSTTProcess == nil || !mlxSTTProcess!.isRunning else {
            Log.info("[MLX-STT] already running"); return
        }
        run(ServerSpec(
            name: "MLX-STT", port: 8725, logFile: "",
            shouldRestart: { [weak self] in self?.sttMode == .localLarge },
            launcher: {
                let script = ConfigManager.configDir + "/start_stt.sh"
                guard FileManager.default.fileExists(atPath: script) else {
                    Log.error("[MLX-STT] start_stt.sh not found"); return nil
                }
                // Fail fast if model missing — saves watching "code=1" loops.
                let modelPath = ConfigManager.configDir + "/models/ggml-large-v3-turbo-q5_0.bin"
                guard FileManager.default.fileExists(atPath: modelPath) else {
                    Log.error("[MLX-STT] ggml-large-v3-turbo-q5_0.bin not found — download it first")
                    NotificationHelper.sendStatus("\u{274C} Large Whisper model not on disk"); return nil
                }
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/bin/bash")
                proc.arguments = [script]
                return proc
            },
            getProcess: { [weak self] in self?.mlxSTTProcess },
            setProcess: { [weak self] p in self?.mlxSTTProcess = p }
        ))
    }

    func stopMLXSTTServer() {
        mlxSTTProcess?.terminationHandler = nil
        mlxSTTProcess?.terminate(); mlxSTTProcess = nil
        Log.info("[MLX-STT] server stopped")
    }

    // MARK: - Hotkeys
    private func setupHotkeys() {
        hotkeys.install()
        hotkeys.installModifierHotkeys(
            fnAction: { [weak self] in self?.toggleRecording() },
            ctrlOptAction: { [weak self] in self?.speakSelected() }
        )
        hotkeys.installLiveDictationHotkey { [weak self] in self?.toggleLiveDictation() }
    }

    // MARK: - Live Dictation
    func toggleLiveDictation() {
        if appState == .recording { stopLiveDictation() }
        else if appState == .idle { startLiveDictation() }
    }

    private func startLiveDictation() {
        guard appState == .idle else { return }
        if sttMode == .localSmall { ModelLifecycle.touchWhisper() }
        do {
            try recorder.start(); SoundCue.recordStart(); appState = .recording
            NotificationHelper.sendStatus("\u{1F3A4} Live dictation... Press Cmd+Shift+Space to stop")
            startLiveTranscription()
        } catch {
            Log.error("[LIVE] failed to start: \(error)"); appState = .idle
        }
    }

    private func stopLiveDictation() {
        guard appState == .recording else { return }
        liveTask?.cancel(); SoundCue.recordStop(); _ = recorder.stop()
        appState = .idle; statusBar.setStopVisible(false)
        NotificationHelper.clearStatus()
        Log.info("[LIVE] dictation stopped")
    }

    // MARK: - Recording (STT)
    func toggleRecording() {
        if appState == .recording { stopRecording() }
        else if appState == .idle { startRecording() }
    }

    func startRecording() {
        guard appState == .idle else { return }
        if sttMode == .localSmall { ModelLifecycle.touchWhisper() }
        do {
            try recorder.start(); SoundCue.recordStart(); appState = .recording
            NotificationHelper.sendStatus("\u{1F534} Recording... Press Fn to stop")
            startLiveTranscription()
        } catch {
            Log.error("[REC] failed: \(error)"); appState = .idle
        }
    }

    func stopRecording() {
        guard appState == .recording else { return }
        liveTask?.cancel(); SoundCue.recordStop()
        let buffers = recorder.stop()
        appState = .processing; statusBar.setStopVisible(true)
        sttTask = Task { [weak self] in
            guard let self else { return }
            await TranscriptionService.process(
                buffers: buffers, api: api,
                history: history, usage: usage, sttMode: sttMode
            )
            await self.finishSpeech(refresh: true)
        }
    }

    private func startLiveTranscription() {
        liveTask = Task { [weak self] in
            guard let self else { return }
            await TranscriptionService.liveLoop(recorder: recorder, api: api, usage: usage, sttMode: sttMode)
        }
    }

    // MARK: - TTS
    /// Shared tail for TTS tasks: drop back to idle + optionally refresh UI.
    @MainActor
    private func finishSpeech(refresh: Bool) {
        if !TTSDialog.shared.isVisible {
            appState = .idle; statusBar.setStopVisible(false)
        }
        if refresh { statusBar.refreshHistory(); statusBar.refreshCost() }
    }

    /// Cancel in-flight TTS, stop player, warm kokoro, flip to speaking.
    /// Returns false if `requireIdle` is set and we weren't idle.
    @discardableResult
    private func beginSpeaking(requireIdle: Bool = false) -> Bool {
        if ttsEngine == .fast { ModelLifecycle.touchKokoro() }
        ttsTask?.cancel(); player.stop()
        if requireIdle && appState != .idle { return false }
        appState = .speaking; statusBar.setStopVisible(true)
        return true
    }

    func jumpToChunk(_ index: Int) {
        Log.info("[TTS] jumpToChunk \(index)")
        beginSpeaking()
        ttsTask = Task { [weak self] in
            guard let self else { return }
            await SpeechService.resumeFromChunk(
                startAt: index, api: api, player: player, voice: currentVoice,
                model: currentTTSModel, rate: playbackRate, usage: usage
            )
            await self.finishSpeech(refresh: false)
        }
    }

    /// Always restarts the chunk at the given time offset — in-place seek
    /// would require knowing which chunk the player is on, which we don't.
    func jumpToWord(chunk: Int, time: TimeInterval) {
        Log.info("[TTS] jumpToWord chunk=\(chunk) t=\(String(format: "%.2f", time))")
        beginSpeaking()
        ttsTask = Task { [weak self] in
            guard let self else { return }
            await SpeechService.resumeFromChunk(
                startAt: chunk, api: api, player: player, voice: currentVoice,
                model: currentTTSModel, rate: playbackRate, usage: usage,
                startTime: time
            )
            await self.finishSpeech(refresh: false)
        }
    }

    func speakSelected() {
        Log.info("[TTS] speakSelected invoked (state=\(appState))")
        if appState == .speaking && player.paused {
            player.togglePause(); TTSDialog.shared.setPaused(false)
            statusBar.updateIcon(.speaking); Log.info("[TTS] resumed"); return
        }
        if appState == .speaking && !player.paused {
            player.togglePause(); TTSDialog.shared.setPaused(true)
            statusBar.updateIcon(.processing); Log.info("[TTS] paused"); return
        }
        guard beginSpeaking(requireIdle: true) else { return }
        ttsTask = Task { [weak self] in
            guard let self else { return }
            await SpeechService.speak(
                api: api, player: player, voice: currentVoice, model: currentTTSModel,
                rate: playbackRate, history: history, usage: usage
            )
            await self.finishSpeech(refresh: true)
        }
    }

    // MARK: - Replay
    func replayRecording() {
        guard let entry = history.load().last, let path = entry.ttsWavPath else { return }
        replayEntry(path: path)
    }

    func replayEntry(path: String) {
        ttsTask?.cancel(); player.stop()
        appState = .speaking; statusBar.setStopVisible(true)
        ttsTask = Task { [weak self] in
            guard let self else { return }
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                await player.play(data: data, rate: playbackRate)
            }
            await MainActor.run {
                self.appState = .idle; self.statusBar.setStopVisible(false)
            }
        }
    }

    func reuseText(_ text: String) {
        beginSpeaking()
        ttsTask = Task { [weak self] in
            guard let self else { return }
            await SpeechService.speakDirect(
                text: text, api: api, player: player, voice: currentVoice,
                model: currentTTSModel, rate: playbackRate, history: history, usage: usage
            )
            await self.finishSpeech(refresh: true)
        }
    }

    // MARK: - Retry
    func retryPending(timestamp: String) {
        if sttMode == .localSmall { ModelLifecycle.touchWhisper() }
        // Detached so stopAll() doesn't cancel it.
        Task.detached { [weak self] in
            guard let self else { return }
            await MainActor.run { self.appState = .processing }
            await TranscriptionService.retryPending(
                timestamp: timestamp, api: self.api,
                history: self.history, usage: self.usage, sttMode: self.sttMode
            )
            await MainActor.run {
                self.appState = .idle
                self.statusBar.refreshHistory(); self.statusBar.refreshCost()
            }
        }
    }

    // MARK: - Stop / Quit
    func stopAll() {
        sttTask?.cancel(); ttsTask?.cancel(); liveTask?.cancel()
        player.stop()
        if appState == .recording { _ = recorder.stop() }
        appState = .idle; statusBar.setStopVisible(false)
        NotificationHelper.clearStatus()
        Log.info("[STOP] all stopped")
    }

    /// SIGTERM then SIGKILL after 300ms — mlx_audio.server sometimes wedges
    /// mid-model-load and won't honor SIGTERM. Hard-exit 1s later because
    /// terminate(nil) can stall on any lingering window.
    func quit() {
        Log.info("[QUIT] user requested quit")
        hotkeys.unregisterAll(); recorder.stop(); player.stop()
        let children = [kokoroProcess, whisperProcess, mlxSTTProcess].compactMap { $0 }
        for p in children { p.terminate() }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            for p in children where p.isRunning { kill(p.processIdentifier, SIGKILL) }
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                                 arguments: ["-9", "-f", "mlx_audio.server"])
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/pkill"),
                                 arguments: ["-9", "-f", "whisper-server"])
        }
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Log.info("[QUIT] terminate(nil) stalled — exiting hard")
                exit(0)
            }
        }
    }
}
