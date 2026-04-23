import Foundation

enum DictionaryCorrector {
    static func apply(to text: String) -> String {
        let entries = ConfigManager.dictionaryEntries()
        return apply(to: text, entries: entries)
    }

    static func apply(to text: String, entries: [ConfigManager.DictionaryEntry]) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }

        var corrected = applyPhraseAliases(to: text, entries: entries)
        let singleWordEntries = entries.filter { isSingleWord($0.canonical) }
        guard !singleWordEntries.isEmpty else { return corrected }

        let pattern = #"\b[\p{L}][\p{L}'-]*\b"#
        let regex = try! NSRegularExpression(pattern: pattern, options: [])
        let nsText = corrected as NSString
        let matches = regex.matches(in: corrected, options: [], range: NSRange(location: 0, length: nsText.length))

        for match in matches.reversed() {
            let token = nsText.substring(with: match.range)
            guard let replacement = replacement(for: token, entries: singleWordEntries),
                  replacement != token else { continue }
            corrected = (corrected as NSString).replacingCharacters(in: match.range, with: replacement)
        }

        return corrected
    }

    private static func applyPhraseAliases(to text: String, entries: [ConfigManager.DictionaryEntry]) -> String {
        var corrected = text
        for entry in entries {
            let canonical = entry.canonical
            let phrases = ([canonical] + entry.aliases).filter { !$0.isEmpty && $0.contains(" ") }
            for phrase in phrases {
                corrected = replaceExactPhrase(phrase, with: canonical, in: corrected)
            }
        }
        return corrected
    }

    private static func replaceExactPhrase(_ phrase: String, with canonical: String, in text: String) -> String {
        let escaped = NSRegularExpression.escapedPattern(for: phrase)
        let regex = try! NSRegularExpression(pattern: "\\b\(escaped)\\b", options: [.caseInsensitive])
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        var output = text
        for match in matches.reversed() {
            output = (output as NSString).replacingCharacters(in: match.range, with: canonical)
        }
        return output
    }

    private static func replacement(for token: String, entries: [ConfigManager.DictionaryEntry]) -> String? {
        let normalizedToken = token.lowercased()

        for entry in entries {
            if normalizedToken == entry.canonical.lowercased() {
                return entry.canonical
            }

            for alias in entry.aliases where isSingleWord(alias) {
                if normalizedToken == alias.lowercased() {
                    return entry.canonical
                }
            }
        }

        return nil
    }

    private static func isSingleWord(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).contains(" ")
    }

}
