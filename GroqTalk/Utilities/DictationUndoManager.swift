import Foundation
import NaturalLanguage

enum DictationUndoManager {
    private static var lastSentenceDeletionCount = 0
    private static var lastSentencePreview = ""

    static func recordPastedText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastSentenceDeletionCount = 0
            lastSentencePreview = ""
            return
        }

        let range = lastSentenceRange(in: trimmed)
        let preview = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        var deleteCount = trimmed.distance(from: range.lowerBound, to: trimmed.endIndex)
        if range.lowerBound > trimmed.startIndex {
            let previous = trimmed[trimmed.index(before: range.lowerBound)]
            if previous.isWhitespace { deleteCount += 1 }
        }

        lastSentenceDeletionCount = deleteCount
        lastSentencePreview = preview
    }

    static func consumeDeleteInstruction() -> (count: Int, preview: String)? {
        guard lastSentenceDeletionCount > 0 else { return nil }
        defer {
            lastSentenceDeletionCount = 0
            lastSentencePreview = ""
        }
        return (lastSentenceDeletionCount, lastSentencePreview)
    }

    private static func lastSentenceRange(in text: String) -> Range<String.Index> {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var lastRange = text.startIndex..<text.endIndex
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            if text[range].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                lastRange = range
            }
            return true
        }

        return lastRange
    }
}
