import Foundation

struct HistoryEntry: Codable {
    let timestamp: String
    var wavPath: String?
    var ttsWavPath: String?
    var transcript: String?
    var cleaned: String?
    var pending: Bool?  // true = recording saved but transcription failed
}

final class HistoryManager {

    private let dir = ConfigManager.configDir + "/history"
    private let maxEntries = 10

    /// Save a completed transcription
    func addEntry(wavBytes: Data, transcript: String, cleaned: String) {
        let ts = Self.timestamp()
        let wavPath = dir + "/rec_\(ts).wav"
        try? wavBytes.write(to: URL(fileURLWithPath: wavPath))

        var entries = load()
        entries.append(HistoryEntry(timestamp: ts, wavPath: wavPath, transcript: transcript, cleaned: cleaned))
        prune(&entries)
        save(entries)
        Log.info("[HISTORY] saved entry \(ts) (\(wavBytes.count) bytes WAV)")
    }

    /// Save recording immediately (before API call) — marked as pending
    func savePendingRecording(wavBytes: Data) -> String {
        let ts = Self.timestamp()
        let wavPath = dir + "/rec_\(ts).wav"
        try? wavBytes.write(to: URL(fileURLWithPath: wavPath))

        var entries = load()
        entries.append(HistoryEntry(timestamp: ts, wavPath: wavPath, pending: true))
        prune(&entries)
        save(entries)
        Log.info("[HISTORY] saved pending recording \(ts) (\(wavBytes.count) bytes)")
        return ts
    }

    /// Mark a pending entry as completed with transcript
    func completePending(timestamp: String, transcript: String, cleaned: String) {
        var entries = load()
        if let idx = entries.firstIndex(where: { $0.timestamp == timestamp }) {
            entries[idx].transcript = transcript
            entries[idx].cleaned = cleaned
            entries[idx].pending = nil
            save(entries)
            Log.info("[HISTORY] completed pending \(timestamp)")
        }
    }

    /// Get WAV data for a pending entry
    func getPendingWav(timestamp: String) -> Data? {
        let entries = load()
        guard let entry = entries.first(where: { $0.timestamp == timestamp }),
              let path = entry.wavPath else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    func saveTTSToHistory(text: String, ttsWavBytes: Data) {
        let ts = Self.timestamp()
        let ttsPath = dir + "/tts_\(ts).wav"
        try? ttsWavBytes.write(to: URL(fileURLWithPath: ttsPath))

        var entries = load()
        // Try to attach to existing entry with matching text
        if let idx = entries.lastIndex(where: { $0.cleaned == text || $0.transcript == text }) {
            entries[idx].ttsWavPath = ttsPath
        } else {
            entries.append(HistoryEntry(timestamp: ts, ttsWavPath: ttsPath, cleaned: text))
            Log.info("[HISTORY] saved standalone TTS \(ts) (\(ttsWavBytes.count) bytes)")
        }
        prune(&entries)
        save(entries)
    }

    func findCachedTTS(text: String) -> Data? {
        let entries = load()
        if let entry = entries.last(where: { ($0.cleaned == text || $0.transcript == text) && $0.ttsWavPath != nil }),
           let path = entry.ttsWavPath {
            return try? Data(contentsOf: URL(fileURLWithPath: path))
        }
        return nil
    }

    func load() -> [HistoryEntry] {
        let path = dir + "/history.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func save(_ entries: [HistoryEntry]) {
        let path = dir + "/history.json"
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func prune(_ entries: inout [HistoryEntry]) {
        while entries.count > maxEntries {
            let old = entries.removeFirst()
            if let p = old.wavPath { try? FileManager.default.removeItem(atPath: p); Log.debug("[HISTORY] deleted \(p)") }
            if let p = old.ttsWavPath { try? FileManager.default.removeItem(atPath: p) }
        }
    }

    static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f.string(from: Date())
    }

    static func relativeTime(_ ts: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        guard let date = f.date(from: ts) else { return ts }
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }
}
