import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Services
    let api = GroqAPIClient()
    let recorder = AudioRecorder()
    let player = AudioPlayer()
    private let previewPlayer = AudioPlayer()
    private let clipPlayer = AudioPlayer()
    let hotkeys = HotkeyService()
    let history = HistoryManager()
    let usage = UsageTracker()
    private let historySearchPanel = HistorySearchPanel()
    private let recentTextPicker = RecentTextPickerPanel.shared
    var statusBar: StatusBarController!
    private var kokoroProcess: Process?
    private var whisperSmallProcess: Process?
    private var whisperLargeProcess: Process?

    // MARK: - State
    enum AppState { case idle, recording, processing, speaking }
    var appState: AppState = .idle { didSet { statusBar?.updateIcon(appState) } }
    var sttMode: ConfigManager.STTMode = ConfigManager.selectedSTTMode {
        didSet {
            ConfigManager.selectedSTTMode = sttMode
            syncSelectedSTTServers()
        }
    }
    var ttsEngine: ConfigManager.TTSEngine = ConfigManager.selectedTTSEngine {
        didSet { ConfigManager.selectedTTSEngine = ttsEngine }
    }
    var currentVoice = ConfigManager.selectedVoice {
        didSet { ConfigManager.selectedVoice = currentVoice }
    }
    var playbackRate: Float = ConfigManager.playbackRate {
        didSet { ConfigManager.playbackRate = playbackRate }
    }
    var currentTTSModel: String { ConfigManager.ttsEngineEntry(ttsEngine).model }
    private var sttTask: Task<Void, Never>?
    private var ttsTask: Task<Void, Never>?
    private var liveTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var clipTask: Task<Void, Never>?
    private var ttsJumpGeneration = 0
    private var previewCache: [String: Data] = [:]
    private var previewVoiceName: String?
    private var dictationInsertionTarget: ClipboardService.InsertionTarget?
    private var lastExternalInsertionTarget: ClipboardService.InsertionTarget?
    private var liveSessionID = 0
    private var sharedServerRecoveryInFlight = false
    private let sessionStartedAt = Date()

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
        // Feed mic RMS to the recording indicator so the VU-meter bars react.
        recorder.onLevel = { level in RecordingIndicator.shared.setLevel(level) }
        TTSDialog.shared.onChunkTap = { [weak self] idx in self?.jumpToChunk(idx) }
        TTSDialog.shared.onWordTap = { [weak self] chunkIndex, wordIndex, suffix in
            self?.jumpToWord(chunkIndex: chunkIndex, wordIndex: wordIndex, visibleSuffix: suffix)
        }
        TTSDialog.shared.voiceOptionsProvider = { [weak self] in
            guard let self else { return ([], "") }
            return (ConfigManager.ttsEngineEntry(self.ttsEngine).voices, self.currentVoice)
        }
        TTSDialog.shared.onChunkVoiceSelect = { [weak self] index, voice in
            self?.speakDialogChunk(index: index, voice: voice)
        }
        TTSDialog.shared.onPauseToggle = { [weak self] in
            guard let self else { return }
            self.player.togglePause()
            TTSDialog.shared.setPaused(self.player.paused)
        }
        TTSDialog.shared.onRecordToggle = { [weak self] in
            self?.toggleRecording()
        }
        TTSDialog.shared.onClose = { [weak self] in
            self?.closeSpeechWindow()
        }
        historySearchPanel.onSpeakEntry = { [weak self] timestamp in
            self?.speakHistoryEntry(timestamp: timestamp)
        }
        historySearchPanel.onPlayWord = { [weak self] timestamp, start, end in
            self?.playHistoryWord(timestamp: timestamp, start: start, end: end)
        }
        historySearchPanel.onEditNote = { [weak self] timestamp in
            self?.editHistoryNote(timestamp: timestamp)
        }
        recentTextPicker.onSelect = { [weak self] text in
            self?.insertRecentText(text)
        }
        recentTextPicker.onDismiss = { [weak self] in
            self?.hotkeys.setTransientKeyHandler(nil)
        }
        TranscriptionService.recoverSharedParakeetServer = { [weak self] reason in
            await self?.recoverSharedParakeetServer(reason: reason)
        }
        ModelLifecycle.kokoroStart  = { [weak self] in self?.startKokoroServer() }
        ModelLifecycle.kokoroStop   = { [weak self] in self?.stopKokoroServer() }
        startKokoroServer()
        ModelLifecycle.markKokoroStarted()
        syncSelectedSTTServers()
        // Warm the selected STT engine at launch so the first live partial
        // doesn't pay the cold-load penalty or trip the shared-server watchdog.
        warmSTT(mode: sttMode)
        // Parakeet rides on the shared mlx_audio server with Kokoro.
        // Whisper Small / Large use dedicated whisper-server daemons so they
        // do not destabilize the shared MLX TTS/STT runtime.

        // Warm the selected TTS engine shortly after launch so the first read
        // doesn't pay the full model download/load cost.
        warmTTS(engine: ConfigManager.selectedTTSEngine, initialDelayMilliseconds: 2_000)
        Log.info("GroqTalk started — Fn (Record) | Fn+Ctrl (Recent Texts) | Ctrl+Option (Speak) | RAM: \(ConfigManager.systemRAMGB)GB | STT: \(sttMode.rawValue) | idleUnload: \(ConfigManager.idleUnloadSeconds)s")
    }

    // MARK: - Server spawn (table-driven)
    /// Everything server-specific lives in `ServerSpec`; all shared plumbing
    /// (stdout redirect, termination handler, circuit-breaker auto-restart)
    /// lives in `run(_:)`.
    private struct ServerSpec {
        let name: String
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
        if !spec.logFile.isEmpty, let fh = Self.appendingLogHandle(at: spec.logFile) {
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

    /// Returns an append-mode handle so we keep any Python traceback from a
    /// previous crashing process. Previously we truncated on every spawn,
    /// which wiped the evidence before debugging could read it.
    private static func appendingLogHandle(at path: String) -> FileHandle? {
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) {
            try? "".write(to: url, atomically: true, encoding: .utf8)
        }
        guard let fh = try? FileHandle(forWritingTo: url) else { return nil }
        fh.seekToEndOfFile()
        let marker = "\n--- \(Date()) respawn ---\n"
        fh.write(marker.data(using: .utf8) ?? Data())
        return fh
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
            name: "KOKORO",
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
                // The mlx_audio server defaults to multiple workers. GroqTalk
                // serializes MLX inference for Metal stability, so one worker
                // avoids extra CPU contention without reducing throughput.
                env["MLX_AUDIO_NUM_WORKERS"] = "1"
                env["TOKENIZERS_PARALLELISM"] = "false"
                proc.environment = env
                // mlx_audio.server writes logs/ in CWD; bundle CWD is EROFS.
                proc.currentDirectoryURL = URL(fileURLWithPath: ConfigManager.configDir)
                return proc
            },
            getProcess: { [weak self] in self?.kokoroProcess },
            setProcess: { [weak self] p in self?.kokoroProcess = p }
        ))
        if kokoroProcess != nil {
            TranscriptionService.noteSharedParakeetServerRestarted()
        }
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

    // MARK: - Dedicated Whisper Servers (8724 / 8725)
    private func syncSelectedSTTServers() {
        switch sttMode {
        case .parakeet:
            stopWhisperServer(.whisperSmall)
            stopWhisperServer(.whisperLarge)
        case .whisperSmall:
            startWhisperServer(.whisperSmall)
            stopWhisperServer(.whisperLarge)
        case .whisperLarge:
            startWhisperServer(.whisperLarge)
            stopWhisperServer(.whisperSmall)
        }
    }

    private func whisperProcess(for mode: ConfigManager.STTMode) -> Process? {
        switch mode {
        case .whisperSmall: return whisperSmallProcess
        case .whisperLarge: return whisperLargeProcess
        case .parakeet: return nil
        }
    }

    private func setWhisperProcess(_ process: Process?, for mode: ConfigManager.STTMode) {
        switch mode {
        case .whisperSmall: whisperSmallProcess = process
        case .whisperLarge: whisperLargeProcess = process
        case .parakeet: break
        }
    }

    private func whisperProcessPattern(for mode: ConfigManager.STTMode) -> String {
        let port = ConfigManager.whisperPort(for: mode) ?? 0
        return "whisper-server.*--port \(port)"
    }

    private func whisperLogPath(for mode: ConfigManager.STTMode) -> String {
        switch mode {
        case .whisperSmall: return ConfigManager.configDir + "/stt_whisper_small.log"
        case .whisperLarge: return ConfigManager.configDir + "/stt_whisper_large.log"
        case .parakeet: return ConfigManager.configDir + "/stt_whisper.log"
        }
    }

    private func whisperArguments(for mode: ConfigManager.STTMode) -> [String]? {
        guard let modelPath = ConfigManager.whisperModelPath(for: mode),
              let port = ConfigManager.whisperPort(for: mode) else {
            return nil
        }

        return [
            "--model", modelPath,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--language", "en",
            "--flash-attn",
            "-bs", "1",
        ]
    }

    private func startWhisperServer(_ mode: ConfigManager.STTMode) {
        guard mode != .parakeet else { return }
        guard ConfigManager.isSTTModeSelectable(mode) else {
            Log.error("[\(mode.rawValue)] whisper prerequisites missing")
            NotificationHelper.sendStatus("\u{274C} \(mode.rawValue) model not available locally")
            return
        }
        guard whisperProcess(for: mode) == nil else { return }

        let name = mode == .whisperSmall ? "WHISPER-SMALL" : "WHISPER-LARGE"
        let port = ConfigManager.whisperPort(for: mode) ?? 0

        run(ServerSpec(
            name: name,
            logFile: whisperLogPath(for: mode),
            shouldRestart: { [weak self] in self?.sttMode == mode },
            launcher: { [weak self] in
                guard let self else { return nil }
                guard let args = self.whisperArguments(for: mode) else { return nil }
                self.killExisting(pattern: self.whisperProcessPattern(for: mode), port: port)
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: ConfigManager.whisperServerBinary)
                proc.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                proc.environment = env
                proc.currentDirectoryURL = URL(fileURLWithPath: ConfigManager.configDir)
                return proc
            },
            getProcess: { [weak self] in self?.whisperProcess(for: mode) },
            setProcess: { [weak self] process in self?.setWhisperProcess(process, for: mode) }
        ))
    }

    private func stopWhisperServer(_ mode: ConfigManager.STTMode) {
        guard mode != .parakeet else { return }
        whisperProcess(for: mode)?.terminate()
        setWhisperProcess(nil, for: mode)
        if let port = ConfigManager.whisperPort(for: mode) {
            killExisting(pattern: whisperProcessPattern(for: mode), port: port)
        }
        Log.info("[\(mode.rawValue)] whisper server stopped")
    }

    // MARK: - Hotkeys
    private func setupHotkeys() {
        hotkeys.install()
        hotkeys.installModifierHotkeys(
            fnAction: { [weak self] in self?.toggleRecording() },
            fnCtrlAction: { [weak self] in self?.toggleRecentTextPicker() },
            ctrlOptAction: { [weak self] in self?.toggleSpeakSelection() }
        )
        hotkeys.installLiveDictationHotkey { [weak self] in self?.toggleLiveDictation() }
        hotkeys.installDeleteLastSentenceHotkey { [weak self] in self?.deleteLastDictationSentence() }
    }

    // MARK: - Live Dictation
    func toggleLiveDictation() {
        if appState == .recording { stopLiveDictation() }
        else if appState == .idle { startLiveDictation() }
    }

    private func startLiveDictation() {
        guard appState == .idle else { return }
        do {
            try beginCapture(status: "\u{1F3A4} Live dictation... Press Cmd+Shift+Space to stop")
        } catch {
            Log.error("[LIVE] failed to start: \(error)"); appState = .idle
        }
    }

    private func stopLiveDictation() {
        guard appState == .recording else { return }
        cancelLiveTranscription(reason: "stop live dictation")
        SoundCue.recordStop(); _ = recorder.stop()
        RecordingIndicator.shared.hide()
        appState = .idle; statusBar.setStopVisible(false)
        NotificationHelper.clearStatus()
        Log.info("[LIVE] dictation stopped")
    }

    // MARK: - Recording (STT)
    func toggleRecording() {
        if appState == .recording { stopRecording() }
        else if appState == .speaking {
            interruptSpeechForRecording()
            startRecording()
        }
        else if appState == .idle { startRecording() }
    }

    func startRecording() {
        guard appState == .idle else { return }
        dictationInsertionTarget = captureInsertionTargetForNextAction()
        do {
            try beginCapture(status: "\u{1F534} Recording... Press Fn to stop")
        } catch {
            dictationInsertionTarget = nil
            Log.error("[REC] failed: \(error)"); appState = .idle
        }
    }

    func stopRecording() {
        guard appState == .recording else { return }
        cancelLiveTranscription(reason: "stop recording")
        SoundCue.recordStop()
        RecordingIndicator.shared.hide()
        let buffers = recorder.stop()
        let insertionTarget = dictationInsertionTarget
        dictationInsertionTarget = nil
        appState = .processing; statusBar.setStopVisible(true)
        sttTask = Task { [weak self] in
            guard let self else { return }
            await TranscriptionService.process(
                buffers: buffers, api: api,
                history: history, usage: usage,
                sttMode: sttMode,
                insertionTarget: insertionTarget
            )
            await self.finishSpeech(refresh: true)
        }
    }

    private func startLiveTranscription() {
        let sessionID = beginLiveTranscriptionSession()
        liveTask = Task { [weak self] in
            guard let self else { return }
            await TranscriptionService.liveLoop(
                recorder: recorder,
                api: api,
                sttMode: sttMode,
                sessionID: sessionID
            ) { snapshot in
                guard self.liveSessionID == sessionID, self.appState == .recording else {
                    Log.debug("[LIVE] dropped stale snapshot from session \(sessionID)")
                    return
                }
                LiveCaptionPanel.shared.update(snapshot: snapshot)
            }
        }
    }

    private func beginCapture(status: String) throws {
        stopAuxiliaryPlayback()
        try recorder.start()
        SoundCue.recordStart()
        appState = .recording
        RecordingIndicator.shared.show()
        LiveCaptionPanel.shared.show()
        NotificationHelper.sendStatus(status)
        startLiveTranscription()
    }

    private func beginLiveTranscriptionSession() -> Int {
        if liveTask != nil {
            cancelLiveTranscription(reason: "replace existing live session")
        }
        liveSessionID += 1
        Log.info("[LIVE] session \(liveSessionID) registered")
        return liveSessionID
    }

    private func cancelLiveTranscription(reason: String) {
        let previousSession = liveSessionID
        liveTask?.cancel()
        liveTask = nil
        liveSessionID += 1
        LiveCaptionPanel.shared.hide()
        Log.info("[LIVE] invalidated session \(previousSession) (\(reason))")
    }

    @MainActor
    private func recoverSharedParakeetServer(reason: String) async {
        guard !sharedServerRecoveryInFlight else {
            Log.info("[STT HEALTH] recovery already in flight — \(reason)")
            return
        }

        sharedServerRecoveryInFlight = true
        defer { sharedServerRecoveryInFlight = false }

        Log.info("[STT HEALTH] recovering shared 8723 server — \(reason)")
        restartKokoroServer()
        try? await Task.sleep(for: .milliseconds(600))
        await warmParakeetAfterRecovery()
        TranscriptionService.noteSharedParakeetServerRestarted()
    }

    private func warmParakeetAfterRecovery() async {
        await warmSTTWithRetries(
            mode: .parakeet,
            logPrefix: "[STT HEALTH]",
            initialDelayMilliseconds: 0
        )
    }

    private func captureInsertionTargetForNextAction() -> ClipboardService.InsertionTarget? {
        guard let captured = ClipboardService.captureInsertionTarget() else {
            if let lastExternalInsertionTarget {
                Log.debug("[INSERT] reusing previous external target \(lastExternalInsertionTarget.summary)")
            }
            return lastExternalInsertionTarget
        }

        if captured.isCurrentApp {
            if let lastExternalInsertionTarget {
                Log.debug("[INSERT] captured GroqTalk; reusing previous external target \(lastExternalInsertionTarget.summary)")
                return lastExternalInsertionTarget
            }
            Log.debug("[INSERT] captured GroqTalk and no previous external target is available")
            return captured
        }

        lastExternalInsertionTarget = captured
        return captured
    }

    // MARK: - TTS
    /// Shared tail for TTS tasks: drop back to idle + optionally refresh UI.
    @MainActor
    private func finishSpeech(refresh: Bool) {
        appState = .idle
        statusBar.setStopVisible(false)
        if ttsEngine == .qwen, sttMode == .parakeet {
            warmSTT(mode: .parakeet)
        }
        if refresh { statusBar.refreshHistory(); statusBar.refreshCost() }
    }

    /// Cancel in-flight TTS, stop player, warm kokoro, flip to speaking.
    /// Returns false if `requireIdle` is set and we weren't idle.
    @discardableResult
    private func beginSpeaking(requireIdle: Bool = false) -> Bool {
        if ttsEngine == .fast { ModelLifecycle.touchKokoro() }
        ensureTTSAlignmentBackend()
        stopAuxiliaryPlayback()
        ttsTask?.cancel()
        SpeechService.cancelOutstandingFetches(reason: "starting new TTS")
        player.stop()
        if requireIdle && appState != .idle { return false }
        appState = .speaking; statusBar.setStopVisible(true)
        return true
    }

    private func ensureTTSAlignmentBackend() {
        guard let mode = TTSWordAlignmentService.preferredAlignmentMode(),
              mode != .parakeet else { return }
        startWhisperServer(mode)
    }

    private func stopAuxiliaryPlayback() {
        previewVoiceName = nil
        previewTask?.cancel()
        clipTask?.cancel()
        previewPlayer.stop()
        clipPlayer.stop()
    }

    private func interruptSpeechForRecording() {
        let wasQwen = ttsEngine == .qwen
        invalidatePendingTTSJump()
        ttsTask?.cancel()
        SpeechService.cancelOutstandingFetches(reason: "recording started")
        player.stop()
        stopAuxiliaryPlayback()
        TTSDialog.shared.setPaused(false)
        appState = .idle
        statusBar.setStopVisible(false)
        NotificationHelper.clearStatus()
        if wasQwen {
            fallBackToFastTTS(reason: "Qwen was interrupted for recording")
            restartKokoroServer()
            if sttMode == .parakeet { warmSTT(mode: .parakeet) }
        }
        Log.info("[TTS] interrupted for recording")
    }

    private func closeSpeechWindow() {
        let wasQwen = ttsEngine == .qwen
        invalidatePendingTTSJump()
        ttsTask?.cancel()
        SpeechService.cancelOutstandingFetches(reason: "TTS dialog closed")
        player.stop()
        stopAuxiliaryPlayback()
        TTSDialog.shared.setPaused(false)
        TTSDialog.shared.close()
        appState = .idle
        statusBar.setStopVisible(false)
        NotificationHelper.clearStatus()
        if wasQwen {
            fallBackToFastTTS(reason: "Qwen dialog was closed")
            restartKokoroServer()
            if sttMode == .parakeet { warmSTT(mode: .parakeet) }
        }
        Log.info("[TTS] closed by toggle")
    }

    private func fallBackToFastTTS(reason: String) {
        guard ttsEngine != .fast else { return }
        ttsEngine = .fast
        currentVoice = ConfigManager.preferredVoice(for: .fast)
        statusBar.refreshTTSSelection(engine: .fast)
        Log.info("[TTS] switched back to Kokoro — \(reason)")
    }

    func jumpToChunk(_ index: Int) {
        Log.info("[TTS] jumpToChunk \(index)")
        if SpeechService.seekToWordIfCurrentlyPlaying(dialogIndex: index, wordIndex: 0, player: player) {
            return
        }
        let delayMS = SpeechService.hasCachedAudio(dialogIndex: index) ? 0 : nil
        scheduleTTSJump(label: "chunk \(index)", delayOverrideMilliseconds: delayMS) { [weak self] in
            guard let self else { return nil }
            return Task { [weak self] in
                guard let self else { return }
                await SpeechService.resumeFromChunk(
                    startAt: index, api: api, player: player, voice: currentVoice,
                    model: currentTTSModel, rate: playbackRate, usage: usage
                )
                await self.finishSpeech(refresh: false)
            }
        }
    }

    func jumpToWord(chunkIndex: Int, wordIndex: Int, visibleSuffix: String? = nil) {
        Log.info("[TTS] jumpToWord chunk=\(chunkIndex) word=\(wordIndex)")
        if SpeechService.seekToWordIfCurrentlyPlaying(dialogIndex: chunkIndex, wordIndex: wordIndex, player: player) {
            return
        }
        let delayMS = SpeechService.hasCachedAudio(dialogIndex: chunkIndex) ? 0 : nil
        scheduleTTSJump(label: "word \(chunkIndex)/\(wordIndex)", delayOverrideMilliseconds: delayMS) { [weak self] in
            guard let self else { return nil }
            return Task { [weak self] in
                guard let self else { return }
                await SpeechService.resumeFromWord(
                    chunkIndex: chunkIndex,
                    wordIndex: wordIndex,
                    api: api,
                    player: player,
                    voice: currentVoice,
                    model: currentTTSModel,
                    rate: playbackRate,
                    usage: usage,
                    firstChunkSuffixOverride: visibleSuffix
                )
                await self.finishSpeech(refresh: false)
            }
        }
    }

    private func invalidatePendingTTSJump() {
        ttsJumpGeneration &+= 1
    }

    private func scheduleTTSJump(
        label: String,
        delayOverrideMilliseconds: Int? = nil,
        makeTask: @escaping () -> Task<Void, Never>?
    ) {
        invalidatePendingTTSJump()
        let generation = ttsJumpGeneration
        ttsTask?.cancel()
        player.stop()

        let delayMS = delayOverrideMilliseconds ?? (ttsEngine == .qwen ? 450 : 90)
        Log.debug("[TTS] scheduled \(label) jump in \(delayMS)ms")
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delayMS)) { [weak self] in
            guard let self, self.ttsJumpGeneration == generation else { return }
            _ = self.beginSpeaking()
            self.ttsTask = makeTask()
        }
    }

    func toggleSpeakSelection() {
        let dialogVisible = TTSDialog.shared.isVisible
        Log.info("[TTS] toggleSpeakSelection (state=\(appState), dialog=\(dialogVisible))")
        if dialogVisible || appState == .speaking {
            closeSpeechWindow()
            return
        }
        speakSelected()
    }

    func speakSelected() {
        Log.info("[TTS] speakSelected invoked (state=\(appState))")
        invalidatePendingTTSJump()
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
    func replayEntry(path: String) {
        invalidatePendingTTSJump()
        stopAuxiliaryPlayback()
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
        invalidatePendingTTSJump()
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

    func insertRecentText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        _ = ClipboardService.insertText(trimmed, target: lastExternalInsertionTarget)
    }

    func toggleRecentTextPicker() {
        if recentTextPicker.isVisible {
            recentTextPicker.hide()
            return
        }
        _ = captureInsertionTargetForNextAction()

        let entries = HistoryManager.recentInsertableTextEntries(from: history.load(), limit: 5)
        let items = entries.compactMap { entry -> RecentTextPickerItem? in
            guard let text = HistoryManager.displayText(for: entry) else { return nil }
            let title = String(text.prefix(120))
            let subtitle = HistoryManager.relativeTime(entry.timestamp) + " · " + HistoryManager.timeString(from: entry.timestamp)
            return RecentTextPickerItem(text: text, title: title, subtitle: subtitle)
        }
        guard !items.isEmpty else {
            NotificationHelper.sendStatus("\u{274C} No recent text to insert yet")
            return
        }

        recentTextPicker.show(items: items)
        hotkeys.setTransientKeyHandler { [weak self] type, keyCode in
            guard let self, self.recentTextPicker.isVisible else { return false }
            return self.recentTextPicker.handleKey(type: type, keyCode: keyCode)
        }
    }

    func openHistorySearch() {
        historySearchPanel.show(entries: history.load())
    }

    func speakHistoryEntry(timestamp: String) {
        guard let entry = history.load().first(where: { $0.timestamp == timestamp }) else { return }
        let text = (entry.cleaned ?? entry.transcript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reuseText(text)
    }

    func editHistoryNote(timestamp: String) {
        guard let entry = history.load().first(where: { $0.timestamp == timestamp }) else { return }
        hotkeys.disableTap()
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "History Note"
        alert.informativeText = "Add a note for this dictation entry. It will be searchable in the history panel."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.stringValue = entry.note ?? ""
        field.placeholderString = "Example: client phrasing to reuse"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        hotkeys.enableTap()
        guard response == .alertFirstButtonReturn else { return }

        history.updateNote(timestamp: timestamp, note: field.stringValue)
        historySearchPanel.show(entries: history.load())
        NotificationHelper.sendStatus("\u{2705} Note saved", subtitle: String(field.stringValue.prefix(60)))
    }

    func deleteLastDictationSentence() {
        guard let instruction = DictationUndoManager.consumeDeleteInstruction() else {
            NotificationHelper.sendStatus("\u{274C} Nothing to delete")
            return
        }
        guard AccessibilityChecker.isTrusted() else {
            NotificationHelper.sendStatus("\u{274C} Accessibility permission required")
            return
        }

        ClipboardService.deleteBackward(count: instruction.count)
        NotificationHelper.sendStatus("\u{2705} Deleted last sentence", subtitle: instruction.preview)
    }

    func playHistoryWord(timestamp: String, start: TimeInterval, end: TimeInterval) {
        guard let entry = history.load().first(where: { $0.timestamp == timestamp }),
              let path = entry.wavPath,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return }

        stopVoicePreview()
        clipTask?.cancel()
        clipPlayer.stop()
        clipPlayer.reset()
        ttsTask?.cancel()
        player.stop()
        appState = .speaking
        statusBar.setStopVisible(true)

        let leadIn = max(0, start - 0.12)
        let leadOut = max(leadIn + 0.24, end + max(0.18, (end - start) * 1.4))
        clipTask = Task { [weak self] in
            guard let self else { return }
            await clipPlayer.play(data: data, rate: 1.0, startAt: leadIn, endAt: leadOut)
            await MainActor.run {
                self.appState = .idle
                self.statusBar.setStopVisible(false)
            }
        }
    }

    func previewVoice(_ voice: String) {
        guard appState == .idle else { return }
        if previewVoiceName == voice { return }
        previewVoiceName = voice
        previewTask?.cancel()
        previewPlayer.stop()
        previewPlayer.reset()
        previewTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }

            let cacheKey = "\(currentTTSModel)|\(voice)"
            let data: Data
            if let cached = previewCache[cacheKey] {
                data = cached
            } else {
                do {
                    data = try await api.speechData(
                        text: "Hello, this is the \(voice) voice.",
                        voice: voice,
                        model: currentTTSModel
                    )
                    previewCache[cacheKey] = data
                } catch {
                    Log.info("[TTS] voice preview failed for \(voice): \(error.localizedDescription)")
                    return
                }
            }

            guard !Task.isCancelled else { return }
            await previewPlayer.play(data: data, rate: 1.0)
        }
    }

    func stopVoicePreview() {
        previewVoiceName = nil
        previewTask?.cancel()
        previewPlayer.stop()
    }

    private func speakDialogChunk(index: Int, voice: String) {
        guard let session = SpeechService.lastSession,
              session.rawChunks.indices.contains(index) else { return }
        beginSpeaking()
        let text = session.rawChunks[index]
        ttsTask = Task { [weak self] in
            guard let self else { return }
            await SpeechService.speakDirect(
                text: text,
                api: api,
                player: player,
                voice: voice,
                model: currentTTSModel,
                rate: playbackRate,
                history: history,
                usage: usage
            )
            await self.finishSpeech(refresh: true)
        }
    }

    // MARK: - Retry
    func retryPending(timestamp: String) {
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

    func exportSessionMarkdown() {
        do {
            let url = try history.exportSessionMarkdown(
                since: sessionStartedAt,
                activeDialogText: SpeechService.lastSession?.text
            )
            NotificationHelper.sendStatus("\u{2705} Session exported", subtitle: url.lastPathComponent)
        } catch {
            Log.error("[HISTORY] session export failed: \(error)")
            NotificationHelper.sendStatus("\u{274C} Session export failed")
        }
    }

    // MARK: - Stop / Quit
    func stopAll() {
        sttTask?.cancel(); ttsTask?.cancel(); liveTask?.cancel()
        stopAuxiliaryPlayback()
        recentTextPicker.hide()
        player.stop()
        if appState == .recording { _ = recorder.stop() }
        LiveCaptionPanel.shared.hide()
        appState = .idle; statusBar.setStopVisible(false)
        NotificationHelper.clearStatus()
        Log.info("[STOP] all stopped")
    }

    /// Pre-warm a specific STT mode by firing a silent 0.5s WAV at it. This
    /// keeps the first real dictation request from paying the model cold-load
    /// penalty right after the user switches engines.
    func warmSTT(mode: ConfigManager.STTMode) {
        guard ConfigManager.isSTTModeSelectable(mode) else {
            Log.info("[STT] skip warm for \(mode.rawValue) — engine not available locally")
            return
        }
        if mode != .parakeet { startWhisperServer(mode) }
        Log.info("[STT] warming \(mode.rawValue) — first request may take 10-30s if cold")
        Task.detached(priority: .utility) { [weak self] in
            await self?.warmSTTWithRetries(
                mode: mode,
                logPrefix: "[STT]",
                initialDelayMilliseconds: mode == .parakeet ? 600 : 800
            )
        }
    }

    func warmTTS(engine: ConfigManager.TTSEngine, initialDelayMilliseconds: Int = 0) {
        guard ConfigManager.isTTSEngineSelectable(engine) else {
            Log.info("[TTS] skip warm for \(engine.rawValue) — engine not available locally")
            return
        }
        guard engine == .fast else {
            Log.info("[TTS] skip warm for \(engine.rawValue) — premium TTS shares the Parakeet server and loads on first use")
            return
        }
        let entry = ConfigManager.ttsEngineEntry(engine)
        let voice = ConfigManager.preferredVoice(for: engine)
        Log.info("[TTS] warming \(entry.label) — first request may download/load the model if cold")
        Task.detached(priority: .utility) { [api] in
            if initialDelayMilliseconds > 0 {
                try? await Task.sleep(for: .milliseconds(initialDelayMilliseconds))
            }

            let start = CFAbsoluteTimeGetCurrent()
            do {
                _ = try await api.speechData(
                    text: ".",
                    voice: voice,
                    model: entry.model
                )
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                Log.info("[TTS] \(entry.label) warmed in \(String(format: "%.1f", elapsed))s")
            } catch {
                Log.info("[TTS] \(entry.label) warm failed: \(error.localizedDescription)")
            }
        }
    }

    private func warmSTTWithRetries(
        mode: ConfigManager.STTMode,
        logPrefix: String,
        initialDelayMilliseconds: Int,
        maxAttempts: Int = 4
    ) async {
        let wav = AudioProcessor.silentWAV(seconds: 0.5)
        let start = CFAbsoluteTimeGetCurrent()

        if initialDelayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(initialDelayMilliseconds))
        }

        for attempt in 1...maxAttempts {
            do {
                try await performWarmSTTRequest(mode: mode, wav: wav)
                let elapsed = CFAbsoluteTimeGetCurrent() - start
                let label = mode == .parakeet && logPrefix == "[STT HEALTH]"
                    ? "parakeet warmed after recovery"
                    : "\(mode.rawValue) warmed"
                Log.info("\(logPrefix) \(label) in \(String(format: "%.1f", elapsed))s")
                return
            } catch {
                guard attempt < maxAttempts, shouldRetryWarmSTT(error) else {
                    let label = mode == .parakeet && logPrefix == "[STT HEALTH]"
                        ? "parakeet warm after recovery failed"
                        : "\(mode.rawValue) warm failed"
                    Log.info("\(logPrefix) \(label): \(error.localizedDescription)")
                    return
                }

                Log.info(
                    "\(logPrefix) \(mode.rawValue) warm attempt \(attempt) failed: \(error.localizedDescription) — retrying"
                )
                let retryDelay = UInt64(400 * attempt)
                try? await Task.sleep(for: .milliseconds(Int(retryDelay)))
            }
        }
    }

    private func performWarmSTTRequest(mode: ConfigManager.STTMode, wav: Data) async throws {
        if mode == .parakeet {
            _ = try await api.transcribeMLXAudio(
                wavData: wav,
                model: ConfigManager.parakeetModel
            )
            return
        }

        _ = try await api.transcribeWhisperServer(
            wavData: wav,
            baseURL: ConfigManager.sttServerURL(for: mode)
        )
    }

    private func shouldRetryWarmSTT(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        switch nsError.code {
        case NSURLErrorCannotConnectToHost,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorTimedOut,
             NSURLErrorCannotFindHost:
            return true
        default:
            return false
        }
    }

    func quit() {
        Log.info("[QUIT] user requested quit")
        hotkeys.unregisterAll(); recorder.stop(); player.stop(); stopAuxiliaryPlayback()
        recentTextPicker.hide()
        LiveCaptionPanel.shared.hide()
        kokoroProcess?.terminate()
        whisperSmallProcess?.terminate()
        whisperLargeProcess?.terminate()
        let child = kokoroProcess
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            if let p = child, p.isRunning { kill(p.processIdentifier, SIGKILL) }
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
