import Foundation

enum TextCleaner {

    static func clean(_ text: String) -> String {
        var t = text

        // Code blocks → spoken placeholder
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: "see the code in context", options: .regularExpression)
        t = t.replacingOccurrences(of: "`([^`]+)`", with: "$1", options: .regularExpression)

        // URLs → spoken placeholder
        t = t.replacingOccurrences(of: "https?://[^\\s)]+", with: "see the link", options: .regularExpression)

        // File paths (multi-segment like /Users/foo/bar.txt)
        t = t.replacingOccurrences(of: "(?:/[\\w.-]+){2,}", with: "see the file path", options: .regularExpression)

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

        Log.debug("[TTS] cleaned for speech: \(String(t.prefix(120)))")
        return t
    }
}
