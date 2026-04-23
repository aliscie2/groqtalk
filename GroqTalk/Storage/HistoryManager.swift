import Foundation

struct HistoryEntry: Codable {
    let timestamp: String
    var wavPath: String? = nil
    var ttsWavPath: String? = nil
    var transcript: String? = nil
    var cleaned: String? = nil
    var structuredTranscript: StructuredTranscript? = nil
    var note: String? = nil
    var pending: Bool? = nil  // true = recording saved but transcription failed
}

final class HistoryManager {

    private let dir = ConfigManager.configDir + "/history"
    private let sessionsDir = ConfigManager.configDir + "/sessions"
    private let maxEntries = 200

    /// Save a completed transcription
    func addEntry(
        wavBytes: Data,
        transcript: String,
        cleaned: String,
        structuredTranscript: StructuredTranscript? = nil
    ) {
        let ts = Self.timestamp()
        let wavPath = dir + "/rec_\(ts).wav"
        try? wavBytes.write(to: URL(fileURLWithPath: wavPath))

        var entries = load()
        entries.append(
            HistoryEntry(
                timestamp: ts,
                wavPath: wavPath,
                transcript: transcript,
                cleaned: cleaned,
                structuredTranscript: structuredTranscript
            )
        )
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
    func completePending(
        timestamp: String,
        transcript: String,
        cleaned: String,
        structuredTranscript: StructuredTranscript? = nil
    ) {
        var entries = load()
        if let idx = entries.firstIndex(where: { $0.timestamp == timestamp }) {
            entries[idx].transcript = transcript
            entries[idx].cleaned = cleaned
            entries[idx].structuredTranscript = structuredTranscript
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

    func updateNote(timestamp: String, note: String?) {
        var entries = load()
        guard let idx = entries.firstIndex(where: { $0.timestamp == timestamp }) else { return }
        let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[idx].note = (trimmed?.isEmpty == false) ? trimmed : nil
        save(entries)
        Log.info("[HISTORY] updated note for \(timestamp)")
    }

    func load() -> [HistoryEntry] {
        let path = dir + "/history.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return [] }
        return (try? JSONDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    func exportSessionMarkdown(since: Date, activeDialogText: String? = nil) throws -> URL {
        try FileManager.default.createDirectory(
            atPath: sessionsDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let filename = Self.sessionFilename(for: since)
        let url = URL(fileURLWithPath: sessionsDir + "/\(filename).md")
        let markdown = SessionMarkdownExporter.render(entries: load(), since: since, activeDialogText: activeDialogText)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        Log.info("[HISTORY] exported session markdown -> \(url.path)")
        return url
    }

    private func save(_ entries: [HistoryEntry]) {
        let path = dir + "/history.json"
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    static func recentAudioEntries(
        from entries: [HistoryEntry],
        limit: Int,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [HistoryEntry] {
        recentEntries(from: entries, limit: limit) { entry in
            guard let path = entry.ttsWavPath else { return false }
            return fileExists(path)
        }
    }

    static func recentTextEntries(from entries: [HistoryEntry], limit: Int) -> [HistoryEntry] {
        recentEntries(from: entries, limit: limit) { entry in
            if entry.pending == true, entry.wavPath != nil {
                return true
            }
            return entry.wavPath != nil && displayText(for: entry) != nil
        }
    }

    static func recentInsertableTextEntries(from entries: [HistoryEntry], limit: Int) -> [HistoryEntry] {
        recentEntries(from: entries, limit: limit) { entry in
            entry.pending != true && entry.wavPath != nil && displayText(for: entry) != nil
        }
    }

    private static func recentEntries(
        from entries: [HistoryEntry],
        limit: Int,
        where include: (HistoryEntry) -> Bool
    ) -> [HistoryEntry] {
        guard limit > 0 else { return [] }
        var result: [HistoryEntry] = []
        for entry in entries.reversed() {
            guard include(entry) else { continue }
            result.append(entry)
            if result.count == limit { break }
        }
        return result
    }

    static func displayText(for entry: HistoryEntry) -> String? {
        let text = (entry.cleaned ?? entry.transcript ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func prune(_ entries: inout [HistoryEntry]) {
        while entries.count > maxEntries {
            let old = entries.removeFirst()
            if let p = old.wavPath { try? FileManager.default.removeItem(atPath: p); Log.debug("[HISTORY] deleted \(p)") }
            if let p = old.ttsWavPath { try? FileManager.default.removeItem(atPath: p) }
        }
    }

    static func timestamp() -> String {
        timestampFormatter.string(from: Date())
    }

    static func date(from ts: String) -> Date? {
        timestampFormatter.date(from: ts)
    }

    static func timeString(from ts: String) -> String {
        guard let date = date(from: ts) else { return ts }
        return timeFormatter.string(from: date)
    }

    static func sessionFilename(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    static func relativeTime(_ ts: String) -> String {
        guard let date = timestampFormatter.date(from: ts) else { return ts }
        let secs = Int(-date.timeIntervalSinceNow)
        if secs < 60 { return "\(secs)s ago" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        if secs < 86400 { return "\(secs / 3600)h ago" }
        return "\(secs / 86400)d ago"
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
