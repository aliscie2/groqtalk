import Foundation

struct ConfigManager {
    static var shared = ConfigManager()

    static let sampleRate: Int = 16_000
    static let channels: Int = 1

    // Local-only endpoints. Every server is spawned by AppDelegate on launch.
    static let sttBaseURL       = "http://127.0.0.1:8724"   // whisper.cpp (small)
    static let sttLargeURL      = "http://127.0.0.1:8725"   // whisper.cpp (large)
    static let sttMLXAudioURL   = "http://127.0.0.1:8723"   // mlx_audio.server (Parakeet; shared with TTS)
    static let ttsBaseURL       = "http://127.0.0.1:8723"   // mlx_audio.server (Kokoro)

    static let parakeetModel = "mlx-community/parakeet-tdt-0.6b-v2"

    enum STTMode: String { case parakeet, localSmall, localLarge }
    static let sttModels: [(mode: STTMode, label: String, path: String)] = [
        (.parakeet,   "Parakeet TDT (fastest + most accurate)", ""),  // pulled on first use
        (.localSmall, "Local Whisper Small",                    configDir + "/models/ggml-small.en.bin"),
        (.localLarge, "Local Whisper Large",                    configDir + "/models/ggml-large-v3-turbo-q5_0.bin"),
    ]

    static let systemRAM: UInt64 = ProcessInfo.processInfo.physicalMemory
    static let systemRAMGB: Int = Int(systemRAM / (1024 * 1024 * 1024))

    /// Pick the best STT default available on disk. Parakeet gets priority on
    /// 16 GB+ Macs because mlx-audio pulls the model on first use and it beats
    /// Whisper on English benchmarks (HF OpenASR leaderboard).
    static var defaultSTTMode: STTMode {
        if systemRAMGB >= 16 {
            return .parakeet
        }
        let smallPath = sttModels.first(where: { $0.mode == .localSmall })?.path ?? ""
        if FileManager.default.fileExists(atPath: smallPath) { return .localSmall }
        return .localSmall
    }

    // MARK: - TTS

    enum TTSEngine: String { case fast }
    static let ttsEngines: [(engine: TTSEngine, label: String, model: String, voices: [String], defaultVoice: String)] = [
        // Kokoro-82M bf16 — consistent preset voices, fully on disk already.
        // (8-bit variant is ~40% faster but is a separate HF repo; switching
        // mid-session triggers a fresh multi-hundred-MB download that hangs
        // every queued TTS request behind it. Upgrade only as a deliberate
        // pre-downloaded swap.) Fish / Qwen were tried and removed: Fish
        // needs reference audio for voice consistency; Qwen's named speakers
        // didn't produce the expected consistency in testing.
        (.fast, "Kokoro", "mlx-community/Kokoro-82M-bf16",
         ["af_heart", "af_bella", "af_nova", "af_sarah", "am_adam", "am_echo", "am_michael", "bf_emma", "bm_daniel"],
         "af_heart"),
    ]
    static let defaultTTSEngine: TTSEngine = .fast
    static func ttsEngineEntry(_ engine: TTSEngine) -> (label: String, model: String, voices: [String], defaultVoice: String) {
        let e = ttsEngines.first { $0.engine == engine } ?? ttsEngines[0]
        return (e.label, e.model, e.voices, e.defaultVoice)
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
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Log.info("[NOTIFY] using NSUserNotificationCenter")
    }
    static func send(title: String = "GroqTalk", message: String) {
        DispatchQueue.main.async {
            let n = NSUserNotification()
            n.title = title
            n.informativeText = message
            NSUserNotificationCenter.default.deliver(n)
        }
    }
    static func sendStatus(_ message: String, subtitle: String = "") {
        DispatchQueue.main.async {
            let center = NSUserNotificationCenter.default
            for d in center.deliveredNotifications where d.title == "GroqTalk" {
                center.removeDeliveredNotification(d)
            }
            let n = NSUserNotification()
            n.title = "GroqTalk"
            n.subtitle = subtitle
            n.informativeText = message
            center.deliver(n)
        }
    }
    static func clearStatus() {
        DispatchQueue.main.async {
            let center = NSUserNotificationCenter.default
            for d in center.deliveredNotifications where d.title == "GroqTalk" {
                center.removeDeliveredNotification(d)
            }
        }
    }
}
