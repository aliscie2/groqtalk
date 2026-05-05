import Foundation

enum TextCleaner {

    static func clean(_ text: String) -> String {
        var t = text
        var protectedTokens: [String] = []

        // Code blocks → spoken placeholder
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: "see the code in context", options: .regularExpression)
        t = t.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)

        // Markdown file links → speak the visible filename / target basename.
        t = replaceMatches(
            in: t,
            pattern: #"\[([^\]\n]+)\]\(([^)\n]+)\)"#
        ) { match in
            let label = match[safe: 1] ?? ""
            let target = match[safe: 2] ?? ""
            guard let filename = speechFilename(label: label, target: target) else {
                return match[0]
            }
            return protect(filename, in: &protectedTokens)
        }

        // URLs → spoken placeholder
        t = t.replacingOccurrences(of: "https?://[^\\s)]+", with: "see the link", options: .regularExpression)

        // File paths (multi-segment like /Users/foo/bar.txt) → final filename only.
        t = replaceMatches(
            in: t,
            pattern: #"(?<!\w)(?:~)?/(?:[^\s\]\),;:]+/)+[^\s\]\),;:]+(?::\d+(?::\d+)?)?"#
        ) { match in
            guard let filename = basename(from: match[0]) else { return match[0] }
            return protect(filename, in: &protectedTokens)
        }

        // Short file references
        t = t.replacingOccurrences(of: "\\b([\\w-]+)\\.([a-z]{1,4})\\b", with: "$1 dot $2", options: .regularExpression)

        // Markdown
        t = t.replacingOccurrences(of: "#{1,6}\\s*", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\*{1,2}([^*]+)\\*{1,2}", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "^[\\-*]\\s+", with: "", options: .regularExpression)

        // Arrows and operators
        t = t.replacingOccurrences(of: "->", with: " to ")
        t = t.replacingOccurrences(of: "=>", with: " becomes ")
        t = t.replacingOccurrences(of: "==", with: " equals ")
        t = t.replacingOccurrences(of: "!=", with: " not equal to ")
        t = t.replacingOccurrences(of: ">=", with: " greater or equal ")
        t = t.replacingOccurrences(of: "<=", with: " less or equal ")

        // CamelCase → spaces
        t = t.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)

        // snake_case and kebab-case
        t = t.replacingOccurrences(of: "([a-zA-Z])_([a-zA-Z])", with: "$1 $2", options: .regularExpression)
        t = t.replacingOccurrences(of: "([a-zA-Z])-([a-zA-Z])", with: "$1 $2", options: .regularExpression)

        // Common abbreviations
        let abbrevs: [(String, String)] = [
            ("JSON", "jason"), ("API", "A P I"), ("URL", "U R L"),
            ("HTTP", "H T T P"), ("HTTPS", "H T T P S"),
            ("HTML", "H T M L"), ("CSS", "C S S"),
            ("SQL", "sequel"), ("CLI", "C L I"),
            ("SDK", "S D K"), ("JWT", "J W T"),
            ("OAuth", "O Auth"), ("README", "read me"),
            ("TODO", "to do"), ("FIXME", "fix me"),
        ]
        for (abbr, spoken) in abbrevs {
            t = t.replacingOccurrences(of: "\\b\(abbr)\\b", with: spoken, options: .regularExpression)
        }

        // Clean whitespace
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)

        for (index, value) in protectedTokens.enumerated() {
            t = t.replacingOccurrences(of: placeholder(index), with: value)
        }

        Log.debug("[TTS] cleaned for speech: \(String(t.prefix(120)))")
        return t
    }

    private static func replaceMatches(
        in text: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            let captures = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return "" }
                return nsText.substring(with: range)
            }
            let replacement = transform(captures)
            if let range = Range(match.range, in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func protect(_ value: String, in protectedTokens: inout [String]) -> String {
        let token = placeholder(protectedTokens.count)
        protectedTokens.append(value)
        return token
    }

    private static func placeholder(_ index: Int) -> String {
        "GROQTALKPROTECTEDTOKEN\(index)"
    }

    private static func speechFilename(label: String, target: String) -> String? {
        if let labelName = basename(from: label), looksLikeFilename(labelName) {
            return labelName
        }
        if looksLikeFilename(label.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return label.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return basename(from: target)
    }

    private static func basename(from raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<"), value.hasSuffix(">") {
            value.removeFirst()
            value.removeLast()
        }
        value = value.replacingOccurrences(of: #"^\[|\]$"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: #"^file://"#, with: "", options: .regularExpression)

        if let lineRange = value.range(of: #":\d+(?::\d+)?$"#, options: .regularExpression) {
            value.removeSubrange(lineRange)
        }

        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "`'\".,;:)"))
        let separators = CharacterSet(charactersIn: "/\\")
        guard let last = value.components(separatedBy: separators).last,
              !last.isEmpty,
              looksLikeFilename(last) else {
            return nil
        }
        return last
    }

    private static func looksLikeFilename(_ value: String) -> Bool {
        value.range(of: #"^[A-Za-z0-9_.@%+\-]+\.[A-Za-z0-9]{1,8}$"#, options: .regularExpression) != nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
