import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct HistoryRecentEntriesTests {
    static func main() {
        let entries = [
            HistoryEntry(timestamp: "20260422_090000", wavPath: nil, ttsWavPath: "/tmp/tts_old.wav", transcript: nil, cleaned: "old audio", pending: nil),
            HistoryEntry(timestamp: "20260422_090100", wavPath: "/tmp/rec_1.wav", ttsWavPath: nil, transcript: "first text", cleaned: "first text", pending: nil),
            HistoryEntry(timestamp: "20260422_090200", wavPath: nil, ttsWavPath: "/tmp/tts_missing.wav", transcript: nil, cleaned: "missing audio", pending: nil),
            HistoryEntry(timestamp: "20260422_090300", wavPath: "/tmp/rec_2.wav", ttsWavPath: nil, transcript: nil, cleaned: nil, pending: true),
            HistoryEntry(timestamp: "20260422_090400", wavPath: "/tmp/rec_3.wav", ttsWavPath: nil, transcript: "second text", cleaned: "second text", pending: nil),
            HistoryEntry(timestamp: "20260422_090500", wavPath: nil, ttsWavPath: "/tmp/tts_new.wav", transcript: nil, cleaned: "new audio", pending: nil),
        ]

        let audios = HistoryManager.recentAudioEntries(
            from: entries,
            limit: 3,
            fileExists: { $0 != "/tmp/tts_missing.wav" }
        )
        expect(audios.map(\.timestamp) == ["20260422_090500", "20260422_090000"],
               "Expected recent audios to ignore missing files and keep newest matching entries")

        let texts = HistoryManager.recentTextEntries(from: entries, limit: 3)
        expect(texts.map(\.timestamp) == ["20260422_090400", "20260422_090300", "20260422_090100"],
               "Expected recent texts to keep newest text/pending entries regardless of audio-only rows")

        let insertables = HistoryManager.recentInsertableTextEntries(from: entries, limit: 3)
        expect(insertables.map(\.timestamp) == ["20260422_090400", "20260422_090100"],
               "Expected insertable recent texts to skip pending rows and require real reusable text")

        expect(HistoryManager.displayText(for: entries[5]) == "new audio", "Expected display text helper to prefer cleaned text")
        expect(HistoryManager.displayText(for: entries[3]) == nil, "Pending entry without text should not expose display text")

        print("History recent entry tests passed")
    }
}
