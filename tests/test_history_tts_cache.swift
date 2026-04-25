import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct HistoryTTSCacheTests {
    static func main() {
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("groqtalk-home-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: home) }

        setenv("HOME", home.path, 1)

        let history = HistoryManager()
        let text = "Hello from cache isolation \(UUID().uuidString)"
        let kokoroKey = HistoryManager.ttsCacheKey(
            model: "mlx-community/Kokoro-82M-bf16",
            voice: "af_heart"
        )
        let qwenKey = HistoryManager.ttsCacheKey(
            model: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
            voice: "Ryan"
        )

        let kokoroAudio = Data("kokoro".utf8)
        history.saveTTSToHistory(text: text, ttsWavBytes: kokoroAudio, cacheKey: kokoroKey)
        expect(
            history.findCachedTTS(text: text, cacheKey: kokoroKey) == kokoroAudio,
            "Expected Kokoro cache hit for matching text/signature"
        )
        expect(
            history.findCachedTTS(text: text, cacheKey: qwenKey) == nil,
            "Expected Qwen cache miss before any Qwen audio is saved"
        )

        let qwenAudio = Data("qwen".utf8)
        history.saveTTSToHistory(text: text, ttsWavBytes: qwenAudio, cacheKey: qwenKey)
        expect(
            history.findCachedTTS(text: text, cacheKey: qwenKey) == qwenAudio,
            "Expected Qwen cache hit for matching text/signature"
        )
        expect(
            history.findCachedTTS(text: text, cacheKey: kokoroKey) == kokoroAudio,
            "Expected Kokoro cache entry to survive after saving Qwen audio"
        )

        let spokenEntries = history.load().filter { $0.cleaned == text && $0.ttsWavPath != nil }
        expect(spokenEntries.count == 2, "Expected separate history entries for Kokoro and Qwen audio")

        print("History TTS cache tests passed")
    }
}
