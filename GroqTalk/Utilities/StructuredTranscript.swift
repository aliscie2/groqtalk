import Foundation

struct TranscriptWord: Codable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval

    var duration: TimeInterval { max(0, end - start) }
}

struct TranscriptSentence: Codable, Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
    let words: [TranscriptWord]

    var duration: TimeInterval { max(0, end - start) }
}

struct StructuredTranscript: Codable, Equatable {
    let text: String
    let sentences: [TranscriptSentence]

    var hasTimings: Bool {
        sentences.contains { !$0.words.isEmpty }
    }
}

enum StructuredTranscriptBuilder {
    private struct RawResponse: Decodable {
        let text: String?
        let accumulated: String?
        let sentences: [RawSentence]?
        let segments: [RawSegment]?
    }

    private struct RawSentence: Decodable {
        let text: String
        let start: Double
        let end: Double
        let tokens: [RawToken]?
    }

    private struct RawToken: Decodable {
        let text: String
        let start: Double
        let end: Double
        let duration: Double?
    }

    private struct RawSegment: Decodable {
        let text: String
        let start: Double
        let end: Double
        let words: [RawWord]?
    }

    private struct RawWord: Decodable {
        let word: String?
        let text: String?
        let start: Double
        let end: Double
    }

    static func fromNDJSON(_ data: Data) -> StructuredTranscript {
        let raw = String(data: data, encoding: .utf8) ?? ""
        var finalResponse: RawResponse?

        for line in raw.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let response = try? JSONDecoder().decode(RawResponse.self, from: lineData) else { continue }
            finalResponse = response
        }

        if let finalResponse {
            return build(from: finalResponse)
        }

        if let response = try? JSONDecoder().decode(RawResponse.self, from: data) {
            return build(from: response)
        }

        let plain = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return StructuredTranscript(text: plain, sentences: [])
    }

    private static func build(from response: RawResponse) -> StructuredTranscript {
        let baseText = (response.text ?? response.accumulated ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let sentences = response.sentences, !sentences.isEmpty {
            let normalized = sentences.map { sentence in
                let words = words(from: sentence.tokens ?? [])
                let text = sentence.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return TranscriptSentence(
                    text: text.isEmpty ? words.map(\.text).joined(separator: " ") : text,
                    start: sentence.start,
                    end: sentence.end,
                    words: words
                )
            }
            let text = baseText.isEmpty ? normalized.map(\.text).joined(separator: " ") : baseText
            return StructuredTranscript(text: text, sentences: normalized)
        }

        if let segments = response.segments, !segments.isEmpty {
            let normalized = segments.map { segment in
                let words = (segment.words ?? []).compactMap { word -> TranscriptWord? in
                    let token = (word.word ?? word.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !token.isEmpty else { return nil }
                    return TranscriptWord(text: token, start: word.start, end: word.end)
                }
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return TranscriptSentence(
                    text: text.isEmpty ? words.map(\.text).joined(separator: " ") : text,
                    start: segment.start,
                    end: segment.end,
                    words: words
                )
            }
            let text = baseText.isEmpty ? normalized.map(\.text).joined(separator: " ") : baseText
            return StructuredTranscript(text: text, sentences: normalized)
        }

        return StructuredTranscript(text: baseText, sentences: [])
    }

    private static func words(from tokens: [RawToken]) -> [TranscriptWord] {
        guard !tokens.isEmpty else { return [] }

        var words: [TranscriptWord] = []
        var currentText = ""
        var currentStart: Double?
        var currentEnd: Double?

        func flushCurrent() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let start = currentStart, let end = currentEnd else {
                currentText = ""
                currentStart = nil
                currentEnd = nil
                return
            }
            words.append(TranscriptWord(text: trimmed, start: start, end: end))
            currentText = ""
            currentStart = nil
            currentEnd = nil
        }

        for token in tokens {
            let piece = token.text
            let trimmedPiece = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedPiece.isEmpty else { continue }

            let isContinuation = !piece.hasPrefix(" ") && !currentText.isEmpty
            let isStandalonePunctuation = trimmedPiece.range(of: #"^[[:punct:]]+$"#, options: .regularExpression) != nil

            if !isContinuation && !currentText.isEmpty {
                flushCurrent()
            }

            if currentText.isEmpty {
                currentText = trimmedPiece
                currentStart = token.start
                currentEnd = token.end
            } else if isStandalonePunctuation {
                currentText += trimmedPiece
                currentEnd = token.end
                flushCurrent()
            } else {
                currentText += trimmedPiece
                currentEnd = token.end
            }
        }

        flushCurrent()
        return words
    }
}
