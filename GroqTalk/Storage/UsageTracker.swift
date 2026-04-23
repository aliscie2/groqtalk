import Foundation

final class UsageTracker {

    struct DailyLog: Codable {
        var date: String
        var calls: Int = 0
        var sttSeconds: Double = 0
        var ttsChars: Int = 0

        enum CodingKeys: String, CodingKey {
            case date, calls, sttSeconds, whisperSeconds, ttsChars
        }

        init(date: String, calls: Int = 0, sttSeconds: Double = 0, ttsChars: Int = 0) {
            self.date = date
            self.calls = calls
            self.sttSeconds = sttSeconds
            self.ttsChars = ttsChars
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            date = try c.decode(String.self, forKey: .date)
            calls = try c.decodeIfPresent(Int.self, forKey: .calls) ?? 0
            sttSeconds = try c.decodeIfPresent(Double.self, forKey: .sttSeconds)
                ?? c.decodeIfPresent(Double.self, forKey: .whisperSeconds)
                ?? 0
            ttsChars = try c.decodeIfPresent(Int.self, forKey: .ttsChars) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(date, forKey: .date)
            try c.encode(calls, forKey: .calls)
            try c.encode(sttSeconds, forKey: .sttSeconds)
            try c.encode(ttsChars, forKey: .ttsChars)
        }
    }

    private let path = ConfigManager.configDir + "/usage.json"

    func logUsage(kind: String, audioDuration: Double = 0, chars: Int = 0) {
        var logs = loadAll()
        let today = todayStr()
        var entry = logs.first(where: { $0.date == today }) ?? DailyLog(date: today)
        entry.calls += 1
        switch kind {
        case "stt": entry.sttSeconds += audioDuration
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
            totals.sttSeconds += log.sttSeconds
            totals.ttsChars += log.ttsChars
        }

        return (0.0, totals)
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
