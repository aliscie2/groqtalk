import Foundation
import NaturalLanguage

struct DialogEntityAnnotation: Codable, Equatable {
    let text: String
    let kind: String
}

struct DialogChunkPayload: Codable, Equatable {
    let markdown: String
    let plain: String
    let entities: [DialogEntityAnnotation]
    let firstMentions: [String]
    let words: Int
    let isQuestion: Bool
}

struct DialogPayload: Codable, Equatable {
    let chunks: [DialogChunkPayload]
    let playbackRate: Float
}

enum DialogCapabilities {
    static func buildPayload(chunks: [String], playbackRate: Float) -> DialogPayload {
        var seenEntities = Set<String>()
        let payloadChunks = chunks.map { raw -> DialogChunkPayload in
            let markdown = TextPrettifier.prettify(raw)
            let entities = entityAnnotations(in: markdown)

            var firstMentions: [String] = []
            for entity in entities {
                let key = normalizeEntityKey(entity.text)
                guard !key.isEmpty, !seenEntities.contains(key) else { continue }
                seenEntities.insert(key)
                firstMentions.append(entity.text)
            }

            let plain = plainText(from: markdown)
            return DialogChunkPayload(
                markdown: markdown,
                plain: plain,
                entities: entities,
                firstMentions: firstMentions,
                words: wordCount(in: plain),
                isQuestion: isQuestion(plain)
            )
        }
        return DialogPayload(chunks: payloadChunks, playbackRate: playbackRate)
    }

    static func plainText(from text: String) -> String {
        var plain = text
        plain = plain.replacingOccurrences(of: #"```([\s\S]*?)```"#, with: "$1", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"`([^`]+)`"#, with: "$1", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"(?m)^[-*]\s+"#, with: "", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"(?m)^\d{1,3}[.)]\s+"#, with: "", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "$1", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"\*([^*]+)\*"#, with: "$1", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        plain = plain.replacingOccurrences(of: #" +"#, with: " ", options: .regularExpression)
        return plain.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func entityAnnotations(in text: String) -> [DialogEntityAnnotation] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        var entities: [DialogEntityAnnotation] = []
        var seen = Set<String>()

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: options
        ) { tag, range in
            guard let tag, let kind = entityKind(for: tag) else { return true }
            let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "\(kind)|\(normalizeEntityKey(token))"
            guard token.count > 1, !seen.contains(key) else { return true }
            seen.insert(key)
            entities.append(DialogEntityAnnotation(text: token, kind: kind))
            return true
        }

        return entities
    }

    private static func entityKind(for tag: NLTag) -> String? {
        switch tag {
        case .personalName: return "person"
        case .placeName: return "place"
        case .organizationName: return "organization"
        default: return nil
        }
    }

    private static func normalizeEntityKey(_ text: String) -> String {
        text
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: #"[^[:alnum:]]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func wordCount(in text: String) -> Int {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let regex = try? NSRegularExpression(pattern: #"[[:alnum:]']+"#)
        return regex?.numberOfMatches(in: text, options: [], range: range) ?? 0
    }

    private static func isQuestion(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = trimmed.last, "\"'”’)]}".contains(last) {
            trimmed.removeLast()
        }
        return trimmed.hasSuffix("?")
    }
}
