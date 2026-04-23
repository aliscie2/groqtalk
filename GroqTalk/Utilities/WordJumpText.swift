import Foundation

enum WordJumpText {
    static func wordCount(in text: String) -> Int {
        partsPreservingWhitespace(in: text)
            .lazy
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .count
    }

    static func suffix(from text: String, wordIndex: Int) -> String? {
        guard wordIndex >= 0 else { return nil }

        let parts = partsPreservingWhitespace(in: text)
        var currentWordIndex = 0

        for (index, part) in parts.enumerated() {
            guard !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            guard currentWordIndex == wordIndex else {
                currentWordIndex += 1
                continue
            }

            let suffix = parts[index...].joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.isEmpty ? nil : suffix
        }

        return nil
    }

    static func suffixChunks(
        from chunks: [String],
        chunkIndex: Int,
        wordIndex: Int
    ) -> [String]? {
        guard chunks.indices.contains(chunkIndex),
              let firstChunkSuffix = suffix(from: chunks[chunkIndex], wordIndex: wordIndex) else {
            return nil
        }

        return [firstChunkSuffix] + Array(chunks.dropFirst(chunkIndex + 1))
    }

    private static func partsPreservingWhitespace(in text: String) -> [String] {
        guard !text.isEmpty else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let regex = try! NSRegularExpression(pattern: #"\s+|\S+"#, options: [])
        return regex.matches(in: text, options: [], range: range).map {
            nsText.substring(with: $0.range)
        }
    }
}
