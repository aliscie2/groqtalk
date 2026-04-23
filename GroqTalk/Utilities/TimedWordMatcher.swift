import Foundation

struct TimedDialogWord: Equatable {
    let wordIndex: Int
    let start: TimeInterval
    let end: TimeInterval
}

final class LiveWordTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let startWordIndex: Int
    private let playableWordCount: Int
    private let startTime: TimeInterval
    private var exactWords: [TimedDialogWord] = []

    init(startWordIndex: Int, playableWordCount: Int, startTime: TimeInterval) {
        self.startWordIndex = startWordIndex
        self.playableWordCount = playableWordCount
        self.startTime = startTime
    }

    func applyExactWords(_ words: [TimedDialogWord]) {
        guard !words.isEmpty else { return }
        lock.lock()
        exactWords = words.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.wordIndex < rhs.wordIndex }
            return lhs.start < rhs.start
        }
        lock.unlock()
    }

    func currentWordIndex(currentTime: TimeInterval, duration: TimeInterval) -> Int? {
        lock.lock()
        let words = exactWords
        lock.unlock()

        let relativeTime = max(0, currentTime - startTime)
        if !words.isEmpty {
            return TimedWordMatcher.wordIndex(at: relativeTime, in: words)
        }

        return WordHighlightEstimator.estimatedWordIndex(
            startWordIndex: startWordIndex,
            playableWordCount: playableWordCount,
            currentTime: currentTime,
            duration: duration,
            startTime: startTime
        )
    }
}

enum TimedWordMatcher {
    static func buildAlignedWords(
        transcriptWords: [TranscriptWord],
        spokenText: String,
        displayText: String,
        startWordIndex: Int
    ) -> [TimedDialogWord] {
        guard !transcriptWords.isEmpty else { return [] }

        let spokenWords = tokenize(spokenText)
        let displayWords = tokenize(displayText)

        guard !spokenWords.isEmpty,
              displayWords.indices.contains(startWordIndex) else {
            return []
        }

        let visibleDisplayWords = Array(displayWords.dropFirst(startWordIndex))
        let spokenToDisplay = greedyMap(
            source: spokenWords,
            target: visibleDisplayWords,
            targetBaseIndex: startWordIndex
        )
        let transcriptToSpoken = greedyMap(
            source: transcriptWords.map(\.text),
            target: spokenWords,
            targetBaseIndex: 0
        )

        var aligned: [TimedDialogWord] = []
        var seenWordIndices = Set<Int>()

        for transcriptIndex in transcriptWords.indices {
            guard let spokenIndex = transcriptToSpoken[transcriptIndex],
                  let displayIndex = spokenToDisplay[spokenIndex],
                  !seenWordIndices.contains(displayIndex) else {
                continue
            }
            seenWordIndices.insert(displayIndex)
            let word = transcriptWords[transcriptIndex]
            aligned.append(
                TimedDialogWord(
                    wordIndex: displayIndex,
                    start: word.start,
                    end: word.end
                )
            )
        }

        let expectedCoverage = max(1, min(spokenWords.count, transcriptWords.count) / 2)
        guard aligned.count >= expectedCoverage else { return [] }
        return aligned.sorted { lhs, rhs in lhs.start < rhs.start }
    }

    static func wordIndex(at time: TimeInterval, in words: [TimedDialogWord]) -> Int? {
        guard !words.isEmpty else { return nil }
        if time <= words[0].start { return words[0].wordIndex }

        for index in words.indices {
            let word = words[index]
            let nextStart = words.indices.contains(index + 1) ? words[index + 1].start : .greatestFiniteMagnitude
            if time < nextStart {
                return word.wordIndex
            }
        }

        return words.last?.wordIndex
    }

    private static func tokenize(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let regex = try! NSRegularExpression(pattern: #"\S+"#, options: [])
        return regex.matches(in: text, options: [], range: range).map {
            nsText.substring(with: $0.range)
        }
    }

    private static func greedyMap(
        source: [String],
        target: [String],
        targetBaseIndex: Int
    ) -> [Int: Int] {
        guard !source.isEmpty, !target.isEmpty else { return [:] }

        let normalizedTarget = target.map(normalize)
        var mapping: [Int: Int] = [:]
        var targetCursor = 0
        let lookahead = 8

        for sourceIndex in source.indices {
            let normalizedSource = normalize(source[sourceIndex])
            guard !normalizedSource.isEmpty else { continue }
            guard targetCursor < normalizedTarget.count else { break }

            if normalizedTarget[targetCursor] == normalizedSource {
                mapping[sourceIndex] = targetBaseIndex + targetCursor
                targetCursor += 1
                continue
            }

            let maxTargetIndex = min(normalizedTarget.count - 1, targetCursor + lookahead)
            var matchedTargetIndex: Int?
            if targetCursor <= maxTargetIndex {
                for candidateIndex in targetCursor...maxTargetIndex where normalizedTarget[candidateIndex] == normalizedSource {
                    matchedTargetIndex = candidateIndex
                    break
                }
            }

            guard let matchedTargetIndex else { continue }
            mapping[sourceIndex] = targetBaseIndex + matchedTargetIndex
            targetCursor = matchedTargetIndex + 1
        }

        return mapping
    }

    private static func normalize(_ token: String) -> String {
        token
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(
                of: #"(^[^[:alnum:]]+|[^[:alnum:]]+$)"#,
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"[^[:alnum:]']+"#, with: "", options: .regularExpression)
    }
}
