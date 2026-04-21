import Foundation

struct ConfigManager {
    static var shared = ConfigManager()

    var apiKey: String
    var openAIKey: String

    static let sampleRate: Int = 16_000
    static let channels: Int = 1
    static let whisperModel = "whisper-large-v3-turbo"
    static let sttBaseURL = "http://127.0.0.1:8724"       // whisper.cpp (small)
    static let sttLargeURL = "http://127.0.0.1:8725"     // mlx-whisper (large)
    static let sttMLXAudioURL = "http://127.0.0.1:8723"  // mlx_audio.server (Parakeet; shared with TTS)
    static let parakeetModel = "mlx-community/parakeet-tdt-0.6b-v2"

    enum STTMode: String { case groqCloud, parakeet, localSmall, localLarge }
    static let sttModels: [(mode: STTMode, label: String, path: String)] = [
        (.groqCloud,  "Groq Cloud (fastest)",            ""),
        (.parakeet,   "Parakeet (local, accurate)",      ""),  // HF repo; downloaded on first use
        (.localSmall, "Local Whisper Small (fast)",      configDir + "/models/ggml-small.en.bin"),
        (.localLarge, "Local Whisper Large (accurate)",  configDir + "/models/ggml-large-v3-turbo-q5_0.bin"),
    ]

    static let systemRAM: UInt64 = ProcessInfo.processInfo.physicalMemory
    static let systemRAMGB: Int = Int(systemRAM / (1024 * 1024 * 1024))

    static var defaultSTTMode: STTMode {
        if systemRAMGB > 16 {
            // 24GB+ Macs: use large model by default
            let largePath = sttModels.first(where: { $0.mode == .localLarge })?.path ?? ""
            if FileManager.default.fileExists(atPath: largePath) { return .localLarge }
        }
        // 16GB or less: use small model
        return .localSmall
    }
    static let llmModel = "llama-3.3-70b-versatile"
    static let llmSystemPrompt = """
        Fix the grammar, punctuation, and formatting of the following transcribed speech. \
        Keep the original meaning. Return ONLY the cleaned text, nothing else. \
        Do not add any commentary or explanation.
        """
    static let llmSkipWordLimit = 4
    static let ttsBaseURL = "http://127.0.0.1:8723"

    enum TTSEngine: String { case fast, chatterbox }
    static let ttsEngines: [(engine: TTSEngine, label: String, model: String, voices: [String], defaultVoice: String)] = [
        (.fast, "Fast (Kokoro)", "mlx-community/Kokoro-82M-bf16",
         ["af_heart", "af_bella", "af_nova", "af_sarah", "am_adam", "am_echo", "am_michael", "bf_emma", "bm_daniel"],
         "af_heart"),
        (.chatterbox, "High Quality (Chatterbox)", "mlx-community/chatterbox-turbo-fp16",
         ["default"], "default"),
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

    private init() {
        self.apiKey = ConfigManager.loadAPIKey()
        self.openAIKey = ConfigManager.loadOpenAIKey()
        Log.info("GROQ_API_KEY loaded: \(apiKey.isEmpty ? "NO" : "YES")")
        Log.info("OPENAI_API_KEY loaded: \(openAIKey.isEmpty ? "NO" : "YES")")
    }

    static func loadAPIKey() -> String {
        let paths = [
            configDir + "/.env",
            NSHomeDirectory() + "/.env"
        ]
        for path in paths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in contents.components(separatedBy: "\n") {
                    if line.hasPrefix("GROQ_API_KEY=") {
                        let key = String(line.dropFirst("GROQ_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !key.isEmpty { return key }
                    }
                }
            }
        }
        return ProcessInfo.processInfo.environment["GROQ_API_KEY"] ?? ""
    }

    static func loadOpenAIKey() -> String {
        let paths = [
            configDir + "/.env",
            NSHomeDirectory() + "/.env"
        ]
        for path in paths {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                for line in contents.components(separatedBy: "\n") {
                    if line.hasPrefix("OPENAI_API_KEY=") {
                        let key = String(line.dropFirst("OPENAI_API_KEY=".count)).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !key.isEmpty { return key }
                    }
                }
            }
        }
        return ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? ""
    }
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

enum NotificationHelper {
    static func requestPermission() {
        Log.info("[NOTIFY] using NSUserNotificationCenter")
    }

    static func send(title: String, subtitle: String = "", message: String) {
        DispatchQueue.main.async {
            let n = NSUserNotification()
            n.title = title
            n.subtitle = subtitle
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
