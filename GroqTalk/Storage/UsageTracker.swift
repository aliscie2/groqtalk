import Foundation

final class UsageTracker {

    struct DailyLog: Codable {
        var date: String
        var calls: Int = 0
        var whisperSeconds: Double = 0
        var llmTokens: Int = 0
        var ttsChars: Int = 0
    }

    private let path = ConfigManager.configDir + "/usage.json"

    func logUsage(kind: String, audioDuration: Double = 0, tokens: Int = 0, chars: Int = 0) {
        var logs = loadAll()
        let today = todayStr()
        var entry = logs.first(where: { $0.date == today }) ?? DailyLog(date: today)
        entry.calls += 1
        switch kind {
        case "whisper": entry.whisperSeconds += audioDuration
        case "llm": entry.llmTokens += tokens
        case "tts": entry.ttsChars += chars
        default: break
        }
        if let idx = logs.firstIndex(where: { $0.date == today }) { logs[idx] = entry }
        else { logs.append(entry) }
        save(logs)
    }

    func costLastNDays(_ n: Int) -> (Double, DailyLog) {
        let logs = loadAll()
        let cutoff = Calendar.current.date(byAdding: .day, value: -n, to: Date())!
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"

        var totals = DailyLog(date: "")
        for log in logs {
            guard let d = f.date(from: log.date), d >= cutoff else { continue }
            totals.calls += log.calls
            totals.whisperSeconds += log.whisperSeconds
            totals.llmTokens += log.llmTokens
            totals.ttsChars += log.ttsChars
        }

        // Groq STT is free tier; TTS is local (free)
        let whisperCost = 0.0
        let llmCost = Double(totals.llmTokens) / 1_000_000.0 * 0.80
        let ttsCost = 0.0

        return (whisperCost + llmCost + ttsCost, totals)
    }

    private func todayStr() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func loadAll() -> [DailyLog] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return (try? JSONDecoder().decode([DailyLog].self, from: data)) ?? []
    }

    private func save(_ logs: [DailyLog]) {
        if let data = try? JSONEncoder().encode(logs) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
