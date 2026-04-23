import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct TranscriptPostProcessorTests {
    static func main() {
        let cases: [(String, String)] = [
            ("I'm going to, uh, the store", "I'm going to, the store"),
            ("the the cat sat down", "the cat sat down"),
            ("Um, this is, er, actually fine.", "this is, actually fine."),
            ("API API server", "API server"),
            ("desktop slash test", "desktop/test"),
            ("desktop forward slash custom-tools slash groqtalk", "desktop/custom-tools/groqtalk"),
            ("users backslash ali", "users\\ali"),
            ("slash is still a word here", "slash is still a word here"),
        ]

        for (input, expected) in cases {
            let actual = TranscriptPostProcessor.clean(input)
            expect(actual == expected, "Expected `\(expected)` but got `\(actual)` for `\(input)`")
        }

        let structured = StructuredTranscript(
            text: "should we rebuild should we put it on applications again",
            sentences: [
                TranscriptSentence(
                    text: "should we rebuild",
                    start: 0.0,
                    end: 1.3,
                    words: [
                        TranscriptWord(text: "should", start: 0.0, end: 0.3),
                        TranscriptWord(text: "we", start: 0.3, end: 0.5),
                        TranscriptWord(text: "rebuild", start: 0.9, end: 1.3),
                    ]
                ),
                TranscriptSentence(
                    text: "should we put it on applications again",
                    start: 2.2,
                    end: 3.6,
                    words: [
                        TranscriptWord(text: "should", start: 2.2, end: 2.4),
                        TranscriptWord(text: "we", start: 2.4, end: 2.6),
                        TranscriptWord(text: "put", start: 2.6, end: 2.8),
                        TranscriptWord(text: "it", start: 2.8, end: 3.0),
                        TranscriptWord(text: "on", start: 3.0, end: 3.1),
                        TranscriptWord(text: "applications", start: 3.1, end: 3.4),
                        TranscriptWord(text: "again", start: 3.4, end: 3.6),
                    ]
                ),
            ]
        )
        let structuredCleaned = TranscriptPostProcessor.clean(structured)
        expect(
            structuredCleaned == "should we rebuild? should we put it on applications again?",
            "Expected structured punctuation cleanup, got `\(structuredCleaned)`"
        )

        print("TranscriptPostProcessor tests passed")
    }
}
