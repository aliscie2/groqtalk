import Foundation

enum TranscriptPostProcessor {
    static func clean(_ text: String) -> String {
        cleanText(text)
    }

    static func clean(_ transcript: StructuredTranscript) -> String {
        let candidate = pauseAwareText(from: transcript)
        let cleaned = cleanText(candidate)
        if !cleaned.isEmpty { return cleaned }
        return cleanText(transcript.text)
    }

    private static func cleanText(_ text: String) -> String {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return "" }

        cleaned = cleaned.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(
            of: #"\b(?:uh|um|er|ah)\b"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = cleaned.replacingOccurrences(
            of: #"\b([[:alpha:]][[:alpha:]']*)\b(?:\s+\1\b)+"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
        )
        cleaned = normalizeSpokenPathSeparators(cleaned)

        // Normalize punctuation after removing filler tokens.
        cleaned = cleaned.replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"([,;:])(?:\s*\1)+"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"^[,;:]\s*"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s*[,;:]\s*$"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #",\s*([.!?])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"([(\[])\s+"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s+([)\]])"#, with: "$1", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\(\s*\)"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\[\s*\]"#, with: "", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)

        cleaned = DictionaryCorrector.apply(to: cleaned)
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? text.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    private static func normalizeSpokenPathSeparators(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            (#"(?i)\b([~[:alnum:]_./\\-]+)\s+(?:forward\s+)?slash\s+([~[:alnum:]_.-]+)"#, "$1/$2"),
            (#"(?i)\b([~[:alnum:]_./\\-]+)\s+backslash\s+([~[:alnum:]_.-]+)"#, "$1\\\\$2"),
        ]

        var changed = true
        while changed {
            changed = false
            for (pattern, replacement) in rules {
                let next = result.replacingOccurrences(
                    of: pattern,
                    with: replacement,
                    options: .regularExpression
                )
                if next != result {
                    changed = true
                    result = next
                }
            }
        }
        return result
    }

    private static func pauseAwareText(from transcript: StructuredTranscript) -> String {
        guard !transcript.sentences.isEmpty else { return transcript.text }

        var lines: [String] = []

        for index in transcript.sentences.indices {
            let sentence = transcript.sentences[index]
            let nextSentence = transcript.sentences.indices.contains(index + 1) ? transcript.sentences[index + 1] : nil
            let sentenceText = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentenceText.isEmpty {
                lines.append(appendingTerminalPunctuation(to: sentenceText, sentenceEnd: sentence.end, nextSentence: nextSentence))
                continue
            }

            let fromWords = reconstructedSentenceText(sentence, nextSentence: nextSentence)
            lines.append(fromWords)
        }

        return lines.joined(separator: " ")
    }

    private static func reconstructedSentenceText(
        _ sentence: TranscriptSentence,
        nextSentence: TranscriptSentence?
    ) -> String {
        guard !sentence.words.isEmpty else {
            let sentenceText = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return appendingTerminalPunctuation(to: sentenceText, sentenceEnd: sentence.end, nextSentence: nextSentence)
        }

        var pieces: [String] = []
        for index in sentence.words.indices {
            let word = sentence.words[index]
            pieces.append(word.text)

            guard sentence.words.indices.contains(index + 1) else { continue }
            let next = sentence.words[index + 1]
            let gap = max(0, next.start - word.end)
            if shouldInsertComma(after: word.text, before: next.text, gap: gap) {
                pieces[pieces.count - 1] += ","
            }
        }

        let joined = pieces.joined(separator: " ")
        return appendingTerminalPunctuation(to: joined, sentenceEnd: sentence.end, nextSentence: nextSentence)
    }

    private static func shouldInsertComma(after left: String, before right: String, gap: TimeInterval) -> Bool {
        let punctuation = "\",.;:!?)]}"
        guard gap >= 0.5 else { return false }
        guard !left.isEmpty, !right.isEmpty else { return false }
        guard !(punctuation.contains(left.last ?? " ")) else { return false }
        guard !(punctuation.contains(right.first ?? " ")) else { return false }
        return true
    }

    private static func appendingTerminalPunctuation(
        to text: String,
        sentenceEnd: TimeInterval,
        nextSentence: TranscriptSentence?
    ) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        guard !hasSentenceEndingPunctuation(trimmed) else { return trimmed }

        if looksLikeQuestion(trimmed) { return trimmed + "?" }

        if let nextSentence {
            let gap = max(0, nextSentence.start - sentenceEnd)
            if gap >= 0.55 { return trimmed + "." }
        }

        return trimmed + "."
    }

    private static func hasSentenceEndingPunctuation(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else { return false }
        return ".!?".contains(last)
    }

    private static func looksLikeQuestion(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let starters = [
            "who", "what", "when", "where", "why", "how",
            "should", "could", "would", "will", "can", "did",
            "does", "do", "is", "are", "am", "was", "were",
        ]
        return starters.contains { normalized.hasPrefix($0 + " ") || normalized == $0 }
    }
}
