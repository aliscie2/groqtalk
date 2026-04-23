import Foundation

enum SessionMarkdownExporter {
    static func render(
        entries: [HistoryEntry],
        since: Date,
        generatedAt: Date = Date(),
        activeDialogText: String? = nil
    ) -> String {
        let sessionEntries = entries.filter {
            guard let date = HistoryManager.date(from: $0.timestamp) else { return false }
            return date >= since
        }

        let dictations = sessionEntries.filter { $0.wavPath != nil && $0.pending != true }
        let spoken = sessionEntries.filter { $0.ttsWavPath != nil }
        let activeDialog = activeDialogText?.trimmingCharacters(in: .whitespacesAndNewlines)

        var lines: [String] = [
            "# GroqTalk Session",
            "",
            "Started: \(displayTimestamp(since))",
            "Exported: \(displayTimestamp(generatedAt))",
            "",
        ]

        if let activeDialog, !activeDialog.isEmpty, !spoken.contains(where: { $0.cleaned == activeDialog || $0.transcript == activeDialog }) {
            lines.append("## Active Reading Dialog")
            lines.append("")
            appendCodeBlock(activeDialog, language: "md", to: &lines)
        }

        lines.append("## Dictations")
        lines.append("")
        if dictations.isEmpty {
            lines.append("_No dictations captured in this session yet._")
            lines.append("")
        } else {
            for entry in dictations {
                appendDictation(entry, to: &lines)
            }
        }

        lines.append("## Read Aloud")
        lines.append("")
        if spoken.isEmpty {
            lines.append("_No TTS output captured in this session yet._")
            lines.append("")
        } else {
            for entry in spoken {
                appendSpoken(entry, to: &lines)
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func appendDictation(_ entry: HistoryEntry, to lines: inout [String]) {
        lines.append("### \(HistoryManager.timeString(from: entry.timestamp))")
        if let path = entry.wavPath {
            lines.append("Audio: `\(URL(fileURLWithPath: path).lastPathComponent)`")
        }
        lines.append("")
        if let cleaned = entry.cleaned, !cleaned.isEmpty {
            lines.append("Cleaned")
            lines.append("")
            appendCodeBlock(cleaned, language: "text", to: &lines)
        }
        if let transcript = entry.transcript, !transcript.isEmpty, transcript != entry.cleaned {
            lines.append("Raw")
            lines.append("")
            appendCodeBlock(transcript, language: "text", to: &lines)
        }
    }

    private static func appendSpoken(_ entry: HistoryEntry, to lines: inout [String]) {
        lines.append("### \(HistoryManager.timeString(from: entry.timestamp))")
        if let path = entry.ttsWavPath {
            lines.append("Audio: `\(URL(fileURLWithPath: path).lastPathComponent)`")
        }
        lines.append("")
        if let text = entry.cleaned ?? entry.transcript, !text.isEmpty {
            appendCodeBlock(text, language: "md", to: &lines)
        }
    }

    private static func appendCodeBlock(_ text: String, language: String, to lines: inout [String]) {
        lines.append("```\(language)")
        lines.append(text)
        lines.append("```")
        lines.append("")
    }

    private static func displayTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
