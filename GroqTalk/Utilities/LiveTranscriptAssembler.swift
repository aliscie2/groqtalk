import Foundation

struct LiveCaptionSnapshot: Equatable {
    let committedText: String
    let tentativeText: String

    var hasContent: Bool {
        !committedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !tentativeText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LiveTranscriptAssembler {
    private let unstableTailSeconds: TimeInterval
    private let fallbackTentativeWordCount: Int
    private let contextWordLimit: Int

    private var committedWords: [String] = []
    private var lastSnapshot = LiveCaptionSnapshot(committedText: "", tentativeText: "")

    init(
        unstableTailSeconds: TimeInterval = 0.95,
        fallbackTentativeWordCount: Int = 3,
        contextWordLimit: Int = 18
    ) {
        self.unstableTailSeconds = unstableTailSeconds
        self.fallbackTentativeWordCount = fallbackTentativeWordCount
        self.contextWordLimit = contextWordLimit
    }

    mutating func consume(_ transcript: StructuredTranscript) -> LiveCaptionSnapshot? {
        let currentWords = displayWords(from: transcript)
        guard !currentWords.isEmpty else { return nil }

        let stableWords = stablePrefixWords(from: transcript, displayWords: currentWords)
        committedWords = mergeCommittedWords(existing: committedWords, incomingStable: stableWords)

        var tentativeWords = suffixAfterOverlap(base: committedWords, candidate: currentWords)
        if committedWords.isEmpty {
            tentativeWords = currentWords
        }

        let snapshot = LiveCaptionSnapshot(
            committedText: compactContext(from: committedWords),
            tentativeText: displayText(from: tentativeWords)
        )
        guard snapshot.hasContent, snapshot != lastSnapshot else { return nil }
        lastSnapshot = snapshot
        return snapshot
    }

    mutating func reset() {
        committedWords = []
        lastSnapshot = LiveCaptionSnapshot(committedText: "", tentativeText: "")
    }

    private func stablePrefixWords(
        from transcript: StructuredTranscript,
        displayWords: [String]
    ) -> [String] {
        let timedWords = transcript.sentences.flatMap(\.words)
        if !timedWords.isEmpty {
            let duration = max(
                transcript.sentences.last?.end ?? 0,
                timedWords.last?.end ?? 0
            )
            let cutoff = max(0, duration - unstableTailSeconds)
            let stableCount = timedWords.prefix { $0.end <= cutoff }.count
            let clampedCount = min(
                displayWords.count,
                max(0, displayWords.count > 1 ? min(stableCount, displayWords.count - 1) : stableCount)
            )
            return Array(displayWords.prefix(clampedCount))
        }

        let stableCount = max(0, displayWords.count - fallbackTentativeWordCount)
        return Array(displayWords.prefix(stableCount))
    }

    private func displayWords(from transcript: StructuredTranscript) -> [String] {
        let timedWords = transcript.sentences.flatMap(\.words).map(\.text)
        if !timedWords.isEmpty {
            return timedWords.filter { token in
                let normalized = normalize(token)
                return !normalized.isEmpty && !isFiller(normalized)
            }
        }
        return tokenize(transcript.text).filter { !isFiller(normalize($0)) }
    }

    private func mergeCommittedWords(existing: [String], incomingStable: [String]) -> [String] {
        guard !incomingStable.isEmpty else { return existing }
        guard !existing.isEmpty else { return incomingStable }

        let overlap = overlapCount(betweenSuffixOf: existing, andPrefixOf: incomingStable)
        if overlap >= incomingStable.count {
            return existing
        }
        return existing + incomingStable.dropFirst(overlap)
    }

    private func suffixAfterOverlap(base: [String], candidate: [String]) -> [String] {
        guard !candidate.isEmpty else { return [] }
        guard !base.isEmpty else { return candidate }
        let overlap = overlapCount(betweenSuffixOf: base, andPrefixOf: candidate)
        guard overlap < candidate.count else { return [] }
        return Array(candidate.dropFirst(overlap))
    }

    private func overlapCount(betweenSuffixOf base: [String], andPrefixOf candidate: [String]) -> Int {
        let maxOverlap = min(base.count, candidate.count)
        guard maxOverlap > 0 else { return 0 }

        let normalizedBase = base.map(normalize)
        let normalizedCandidate = candidate.map(normalize)

        for overlap in stride(from: maxOverlap, through: 1, by: -1) {
            let baseSlice = normalizedBase.suffix(overlap)
            let candidateSlice = normalizedCandidate.prefix(overlap)
            if Array(baseSlice) == Array(candidateSlice) {
                return overlap
            }
        }
        return 0
    }

    private func compactContext(from words: [String]) -> String {
        guard !words.isEmpty else { return "" }
        let trimmed = Array(words.suffix(contextWordLimit))
        let text = displayText(from: trimmed)
        return words.count > contextWordLimit ? "…" + text : text
    }

    private func displayText(from words: [String]) -> String {
        guard !words.isEmpty else { return "" }
        let joined = words.joined(separator: " ")
        return joined
            .replacingOccurrences(of: #"\s+([,.;:!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func tokenize(_ text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let nsText = trimmed as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let regex = try! NSRegularExpression(pattern: #"\S+"#, options: [])
        return regex.matches(in: trimmed, options: [], range: range).map {
            nsText.substring(with: $0.range)
        }
    }

    private func normalize(_ token: String) -> String {
        token
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(
                of: #"(^[^[:alnum:]]+|[^[:alnum:]]+$)"#,
                with: "",
                options: .regularExpression
            )
    }

    private func isFiller(_ token: String) -> Bool {
        ["uh", "um", "er", "ah"].contains(token)
    }
}
