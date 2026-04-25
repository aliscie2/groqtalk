import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func makeCachedModel(root: URL, repoID: String, snapshot: String) {
    let repoDir = root
        .appendingPathComponent("hub", isDirectory: true)
        .appendingPathComponent("models--" + repoID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    let refsDir = repoDir.appendingPathComponent("refs", isDirectory: true)
    let snapshotDir = repoDir.appendingPathComponent("snapshots/\(snapshot)", isDirectory: true)
    try! FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: snapshotDir, withIntermediateDirectories: true)
    try! snapshot.write(to: refsDir.appendingPathComponent("main"), atomically: true, encoding: .utf8)
}

@main
struct ConfigManagerTTSTests {
    static func main() {
        let fm = FileManager.default
        let hfHome = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("groqtalk-hf-home-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: hfHome, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: hfHome) }

        setenv("HF_HOME", hfHome.path, 1)

        let engineKey = "selectedTTSEngine"
        let voiceKey = "selectedVoice"
        let qwenEnabledKey = "enableSlowQwenTTS"
        let defaults = UserDefaults.standard
        let oldEngine = defaults.string(forKey: engineKey)
        let oldVoice = defaults.string(forKey: voiceKey)
        let oldQwenEnabled = defaults.object(forKey: qwenEnabledKey)

        defer {
            if let oldEngine {
                defaults.set(oldEngine, forKey: engineKey)
            } else {
                defaults.removeObject(forKey: engineKey)
            }
            if let oldVoice {
                defaults.set(oldVoice, forKey: voiceKey)
            } else {
                defaults.removeObject(forKey: voiceKey)
            }
            if let oldQwenEnabled {
                defaults.set(oldQwenEnabled, forKey: qwenEnabledKey)
            } else {
                defaults.removeObject(forKey: qwenEnabledKey)
            }
        }

        defaults.removeObject(forKey: engineKey)
        defaults.removeObject(forKey: voiceKey)
        defaults.removeObject(forKey: qwenEnabledKey)
        expect(ConfigManager.selectedTTSEngine == .fast, "Missing TTS selection should fall back to Kokoro")
        expect(ConfigManager.selectedVoice == "af_heart", "Missing TTS voice should fall back to Kokoro default")
        expect(!ConfigManager.slowQwenTTSEnabled, "Expected slow Qwen to be disabled by default")
        expect(!ConfigManager.isTTSEngineSelectable(.qwen), "Expected Qwen to stay hidden by default")
        expect(ConfigManager.availableTTSEngines.map(\.engine) == [.fast], "Expected only Kokoro when Qwen cache is missing")

        defaults.set("not-a-real-engine", forKey: engineKey)
        expect(ConfigManager.selectedTTSEngine == .fast, "Invalid TTS engine should fall back to Kokoro")

        makeCachedModel(
            root: hfHome,
            repoID: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
            snapshot: "qwen-snap"
        )
        expect(!ConfigManager.isTTSEngineSelectable(.qwen), "Expected cached Qwen to stay hidden until explicitly enabled")
        defaults.set(true, forKey: qwenEnabledKey)
        expect(ConfigManager.slowQwenTTSEnabled, "Expected explicit defaults flag to enable slow Qwen")
        expect(ConfigManager.isTTSEngineSelectable(.qwen), "Expected Qwen to become selectable once cached and explicitly enabled")
        expect(ConfigManager.availableTTSEngines.map(\.engine) == [.fast, .qwen], "Expected Qwen in menu only after explicit opt-in")

        let qwen = ConfigManager.ttsEngineEntry(.qwen)
        expect(qwen.model == "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit", "Expected Qwen model id")
        expect(qwen.defaultVoice == "Ryan", "Expected English-friendly default Qwen voice")
        expect(qwen.voices.contains("Vivian"), "Expected Vivian Qwen voice")
        expect(qwen.voices.contains("Sohee"), "Expected Sohee Qwen voice")
        expect(ConfigManager.ttsEngine(for: qwen.model) == .qwen, "Expected model lookup to resolve the Qwen engine")
        expect(
            ConfigManager.ttsDecodingOptions(for: .qwen)
                == .init(temperature: 0.0, topP: 1.0, topK: 1, repetitionPenalty: 1.0),
            "Expected Qwen decoding to be deterministic"
        )
        expect(
            ConfigManager.ttsChunkProfile(for: .qwen) == .init(mergeUpTo: 220, maxChunk: 420),
            "Expected Qwen chunk profile to favor fewer longer chunks"
        )
        expect(ConfigManager.ttsFetchConcurrency(for: .qwen) == 1, "Expected Qwen fetches to be serialized")
        expect(
            ConfigManager.ttsDecodingOptions(for: .fast)
                == .init(temperature: nil, topP: nil, topK: nil, repetitionPenalty: nil),
            "Expected Kokoro to keep the server defaults"
        )

        defaults.set(ConfigManager.TTSEngine.qwen.rawValue, forKey: engineKey)
        defaults.set("af_heart", forKey: voiceKey)
        expect(ConfigManager.selectedVoice == "Ryan", "Expected invalid stored Kokoro voice to fall back for Qwen")

        defaults.set("Aiden", forKey: voiceKey)
        expect(ConfigManager.selectedVoice == "Aiden", "Expected valid Qwen voice to be preserved")

        print("ConfigManager TTS tests passed")
    }
}
