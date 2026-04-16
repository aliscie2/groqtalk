import Foundation

enum TextPrettifier {
    static func prettify(_ raw: String) -> String {
        var s = raw

        s = s.replacingOccurrences(of: "\\.\\.\\.", with: "\u{2026}", options: .regularExpression)
        s = s.replacingOccurrences(of: " -- ", with: " \u{2014} ")
        s = s.replacingOccurrences(of: "--", with: "\u{2014}")

        s = s.replacingOccurrences(
            of: "(^|\\s)\"([^\"]+)\"",
            with: "$1\u{201C}$2\u{201D}",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "(^|\\s)'([^']+)'",
            with: "$1\u{2018}$2\u{2019}",
            options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "([A-Za-z])'([A-Za-z])",
            with: "$1\u{2019}$2",
            options: .regularExpression
        )

        s = s.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
