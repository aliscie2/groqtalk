import Foundation

struct ConfigManager {
    static let sampleRate: Int = 16_000
    static let channels: Int = 1

    // Local-only endpoints. `mlx_audio.server` hosts Kokoro TTS and
    // Parakeet-TDT STT on 8723. Whisper runs on dedicated whisper-server
    // daemons so it does not contend with Kokoro inside the shared MLX process.
    static let sttMLXAudioURL   = "http://127.0.0.1:8723"
    static let whisperSmallURL  = "http://127.0.0.1:8724"
    static let whisperLargeURL  = "http://127.0.0.1:8725"
    static let ttsBaseURL       = "http://127.0.0.1:8723"
    static let whisperServerBinary = "/opt/homebrew/bin/whisper-server"
    static let whisperSmallPath = configDir + "/models/ggml-small.en.bin"
    static let whisperLargePath = configDir + "/models/ggml-large-v3-turbo-q5_0.bin"

    static let sttModelID: [STTMode: String] = [
        .parakeet: "mlx-community/parakeet-tdt-0.6b-v2",
        .whisperSmall: "mlx-community/whisper-small-asr-fp16",
        .whisperLarge: "mlx-community/whisper-large-v3-turbo-asr-fp16",
    ]
    static let parakeetModel = sttModelID[.parakeet]!

    /// Parakeet is the low-latency default in the current local stack.
    /// Whisper Small / Large run on dedicated whisper.cpp daemons.
    enum STTMode: String { case parakeet, whisperSmall, whisperLarge }
    static let sttModels: [(mode: STTMode, label: String, path: String)] = [
        (.parakeet, "Parakeet", ""),
        (.whisperSmall, "Whisper Small", whisperSmallPath),
        (.whisperLarge, "Whisper Large", whisperLargePath),
    ]
    static var availableSTTModels: [(mode: STTMode, label: String, path: String)] {
        sttModels.filter { isSTTModeSelectable($0.mode) }
    }

    static let systemRAM: UInt64 = ProcessInfo.processInfo.physicalMemory
    static let systemRAMGB: Int = Int(systemRAM / (1024 * 1024 * 1024))

    static var defaultSTTMode: STTMode {
        .parakeet
    }

    private static let selectedSTTModeKey = "selectedSTTMode"
    static var selectedSTTMode: STTMode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedSTTModeKey),
                  let mode = STTMode(rawValue: raw) else {
                return defaultSTTMode
            }
            return isSTTModeSelectable(mode) ? mode : defaultSTTMode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedSTTModeKey) }
    }

    static func isSTTModeSelectable(_ mode: STTMode) -> Bool {
        switch mode {
        case .parakeet:
            return true
        case .whisperSmall:
            return FileManager.default.fileExists(atPath: whisperServerBinary)
                && FileManager.default.fileExists(atPath: whisperSmallPath)
        case .whisperLarge:
            return FileManager.default.fileExists(atPath: whisperServerBinary)
                && FileManager.default.fileExists(atPath: whisperLargePath)
        }
    }

    static func sttServerURL(for mode: STTMode) -> String {
        switch mode {
        case .parakeet: return sttMLXAudioURL
        case .whisperSmall: return whisperSmallURL
        case .whisperLarge: return whisperLargeURL
        }
    }

    static func whisperModelPath(for mode: STTMode) -> String? {
        switch mode {
        case .whisperSmall: return whisperSmallPath
        case .whisperLarge: return whisperLargePath
        case .parakeet: return nil
        }
    }

    static func whisperPort(for mode: STTMode) -> UInt16? {
        switch mode {
        case .whisperSmall: return 8724
        case .whisperLarge: return 8725
        case .parakeet: return nil
        }
    }

    // MARK: - TTS

    enum TTSEngine: String { case fast, qwen }
    struct TTSDecodingOptions: Equatable {
        let temperature: Double?
        let topP: Double?
        let topK: Int?
        let repetitionPenalty: Double?
    }
    struct TTSChunkProfile: Equatable {
        let mergeUpTo: Int
        let maxChunk: Int
    }
    static let qwenCustomVoices = [
        "Vivian", "Serena", "Uncle_Fu", "Dylan", "Eric",
        "Ryan", "Aiden", "Ono_Anna", "Sohee",
    ]
    static let ttsEngines: [(engine: TTSEngine, label: String, model: String, voices: [String], defaultVoice: String)] = [
        // Kokoro-82M bf16 — consistent preset voices and already available
        // locally in this setup.
        (.fast, "Kokoro", "mlx-community/Kokoro-82M-bf16",
         ["af_heart", "af_bella", "af_nova", "af_sarah", "am_adam", "am_echo", "am_michael", "bf_emma", "bm_daniel"],
         "af_heart"),
        // Qwen3-TTS 0.6B CustomVoice — officially supported by mlx-audio,
        // stronger multilingual timbres, but heavier/slower than Kokoro.
        (.qwen, "Qwen3 CustomVoice (Slow)", "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
         qwenCustomVoices,
         "Ryan"),
    ]
    static let defaultTTSEngine: TTSEngine = .fast
    static var availableTTSEngines: [(engine: TTSEngine, label: String, model: String, voices: [String], defaultVoice: String)] {
        ttsEngines.filter { isTTSEngineSelectable($0.engine) }
    }
    static func ttsEngineEntry(_ engine: TTSEngine) -> (label: String, model: String, voices: [String], defaultVoice: String) {
        let e = ttsEngines.first { $0.engine == engine } ?? ttsEngines[0]
        let voices = KokoroVoiceResolver.installedVoices(preferred: e.voices, model: e.model)
        let defaultVoice = voices.contains(e.defaultVoice) ? e.defaultVoice : (voices.first ?? e.defaultVoice)
        return (e.label, e.model, voices, defaultVoice)
    }

    static func ttsEngine(for model: String) -> TTSEngine? {
        ttsEngines.first { $0.model == model }?.engine
    }

    static func ttsDecodingOptions(for engine: TTSEngine) -> TTSDecodingOptions {
        switch engine {
        case .fast:
            return TTSDecodingOptions(
                temperature: nil,
                topP: nil,
                topK: nil,
                repetitionPenalty: nil
            )
        case .qwen:
            // Qwen3-TTS defaults to stochastic decoding in mlx_audio.server.
            // Pinning these values keeps the same preset voice stable across
            // repeated requests and across chunked playback.
            return TTSDecodingOptions(
                temperature: 0.0,
                topP: 1.0,
                topK: 1,
                repetitionPenalty: 1.0
            )
        }
    }

    static func ttsChunkProfile(for engine: TTSEngine) -> TTSChunkProfile {
        switch engine {
        case .fast:
            return TTSChunkProfile(mergeUpTo: 120, maxChunk: 250)
        case .qwen:
            // Favor fewer, longer chunks for the premium engine so prosody
            // and voice color stay more consistent across a read.
            return TTSChunkProfile(mergeUpTo: 220, maxChunk: 420)
        }
    }

    static func ttsFetchConcurrency(for engine: TTSEngine) -> Int {
        switch engine {
        case .fast:
            return 3
        case .qwen:
            return 1
        }
    }

    private static let selectedTTSEngineKey = "selectedTTSEngine"
    static var selectedTTSEngine: TTSEngine {
        get {
            guard let raw = UserDefaults.standard.string(forKey: selectedTTSEngineKey),
                  let engine = TTSEngine(rawValue: raw) else {
                return defaultTTSEngine
            }
            return isTTSEngineSelectable(engine) ? engine : defaultTTSEngine
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: selectedTTSEngineKey) }
    }

    private static let selectedVoiceKey = "selectedVoice"
    static var selectedVoice: String {
        get {
            let stored = UserDefaults.standard.string(forKey: selectedVoiceKey)
            return preferredVoice(for: selectedTTSEngine, storedVoice: stored)
        }
        set { UserDefaults.standard.set(newValue, forKey: selectedVoiceKey) }
    }

    static func preferredVoice(for engine: TTSEngine, storedVoice: String? = nil) -> String {
        let entry = ttsEngineEntry(engine)
        let candidate = storedVoice ?? UserDefaults.standard.string(forKey: selectedVoiceKey)
        if let candidate, entry.voices.contains(candidate) { return candidate }
        return entry.defaultVoice
    }

    static func isTTSEngineSelectable(_ engine: TTSEngine) -> Bool {
        switch engine {
        case .fast:
            return true
        case .qwen:
            return slowQwenTTSEnabled
                && isModelCached(ttsEngines.first { $0.engine == engine }?.model ?? "")
        }
    }

    private static let slowQwenTTSEnabledKey = "enableSlowQwenTTS"
    static var slowQwenTTSEnabled: Bool {
        UserDefaults.standard.bool(forKey: slowQwenTTSEnabledKey)
    }

    private static func isModelCached(_ repoID: String) -> Bool {
        guard !repoID.isEmpty else { return false }
        let repoDir = huggingFaceHubRoot
            .appendingPathComponent("hub", isDirectory: true)
            .appendingPathComponent("models--" + repoID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)

        let refsMain = repoDir.appendingPathComponent("refs/main")
        if let snapshot = try? String(contentsOf: refsMain, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !snapshot.isEmpty {
            let snapshotDir = repoDir.appendingPathComponent("snapshots/\(snapshot)", isDirectory: true)
            if FileManager.default.fileExists(atPath: snapshotDir.path) {
                return true
            }
        }

        let snapshotsDir = repoDir.appendingPathComponent("snapshots", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(at: snapshotsDir, includingPropertiesForKeys: nil),
              !contents.isEmpty else {
            return false
        }
        return contents.contains { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    private static var huggingFaceHubRoot: URL = {
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"], !hfHome.isEmpty {
            return URL(fileURLWithPath: hfHome, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".cache/huggingface", isDirectory: true)
    }()

    private static let playbackRateKey = "playbackRate"
    static var playbackRate: Float {
        get {
            if UserDefaults.standard.object(forKey: playbackRateKey) == nil { return 1.25 }
            let value = UserDefaults.standard.float(forKey: playbackRateKey)
            return value > 0 ? value : 1.25
        }
        set { UserDefaults.standard.set(newValue, forKey: playbackRateKey) }
    }

    static let dictionaryPath = configDir + "/dictionary.txt"

    private static let showTTSDialogKey = "showTTSDialog"
    static var showTTSDialog: Bool {
        get {
            if UserDefaults.standard.object(forKey: showTTSDialogKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: showTTSDialogKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: showTTSDialogKey) }
    }

    private static let denoiseBeforeSTTKey = "denoiseBeforeSTT"
    /// When on, the recorded WAV is routed through mlx_audio.server's
    /// /v1/audio/separations endpoint to isolate voice before STT. Opt-in
    /// (default false) because the endpoint is experimental and adds latency.
    static var denoiseBeforeSTT: Bool {
        get { UserDefaults.standard.bool(forKey: denoiseBeforeSTTKey) }
        set { UserDefaults.standard.set(newValue, forKey: denoiseBeforeSTTKey) }
    }

    /// Seconds of inactivity before whisper/kokoro servers are unloaded to free RAM.
    /// 0 disables hot-swap (servers stay resident). Default 0 — user opts in.
    private static let idleUnloadSecondsKey = "idleUnloadSeconds"
    static var idleUnloadSeconds: Int {
        get {
            if UserDefaults.standard.object(forKey: idleUnloadSecondsKey) == nil { return 0 }
            return UserDefaults.standard.integer(forKey: idleUnloadSecondsKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: idleUnloadSecondsKey) }
    }

    static func loadDictionary() -> String {
        guard let content = try? String(contentsOfFile: dictionaryPath, encoding: .utf8) else { return "" }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct DictionaryEntry {
        let canonical: String
        let aliases: [String]
    }

    static func dictionaryEntries() -> [DictionaryEntry] {
        loadDictionary()
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { line -> [DictionaryEntry] in
                if let range = line.range(of: "=>") {
                    let aliasPart = line[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                    let canonicalPart = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !aliasPart.isEmpty, !canonicalPart.isEmpty else { return [] }
                    let aliases = aliasPart
                        .components(separatedBy: ",")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    guard !aliases.isEmpty else { return [] }
                    return [DictionaryEntry(canonical: canonicalPart, aliases: aliases)]
                }

                return line
                    .components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .map { DictionaryEntry(canonical: $0, aliases: []) }
            }
    }

    static let silenceThreshold: Float = 0.005
    static let silenceAboveRatio: Float = 0.1

    static let iconIdle = "\u{1F399}"
    static let iconRecording = "\u{1F534}"
    static let iconProcessing = "\u{23F3}"
    static let iconSpeaking = "\u{1F50A}"

    static let configDir: String = {
        let path = NSHomeDirectory() + "/.config/groqtalk"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let historyPath = path + "/history"
        try? FileManager.default.createDirectory(atPath: historyPath, withIntermediateDirectories: true)
        return path
    }()

    private init() {}
}

// MARK: - Logging

enum Log {
    private static let logFile: FileHandle? = {
        let path = ConfigManager.configDir + "/groqtalk.log"
        FileManager.default.createFile(atPath: path, contents: nil)
        return FileHandle(forWritingAtPath: path)
    }()

    static func info(_ msg: String) { write("INFO", msg) }
    static func error(_ msg: String) { write("ERROR", msg) }
    static func debug(_ msg: String) { write("DEBUG", msg) }

    private static func write(_ level: String, _ msg: String) {
        let ts = DateFormatter.logFormatter.string(from: Date())
        let line = "\(ts) [\(level)] \(msg)\n"
        logFile?.seekToEndOfFile()
        logFile?.write(line.data(using: .utf8) ?? Data())
    }
}

extension DateFormatter {
    static let logFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Notifications

import AppKit
import UserNotifications

enum NotificationHelper {
    private static let statusNotificationID = "com.groqtalk.status"

    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Log.info("[NOTIFY] using UserNotifications")
    }

    static func send(title: String = "GroqTalk", message: String) {
        post(
            id: "com.groqtalk.message.\(UUID().uuidString)",
            title: title,
            subtitle: "",
            body: message
        )
    }

    static func sendStatus(_ message: String, subtitle: String = "") {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [statusNotificationID])
        center.removePendingNotificationRequests(withIdentifiers: [statusNotificationID])
        post(id: statusNotificationID, title: "GroqTalk", subtitle: subtitle, body: message)
    }

    static func clearStatus() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [statusNotificationID])
        center.removePendingNotificationRequests(withIdentifiers: [statusNotificationID])
    }

    private static func post(id: String, title: String, subtitle: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Log.error("[NOTIFY] failed to deliver: \(error.localizedDescription)") }
        }
    }
}
