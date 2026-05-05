import Foundation

struct ConfigManager {
    struct DictionaryEntry {
        let canonical: String
        let aliases: [String]
    }

    static func dictionaryEntries() -> [DictionaryEntry] {
        [
            DictionaryEntry(canonical: "qwen", aliases: ["quan"]),
            DictionaryEntry(canonical: "tauri", aliases: ["ta uri"]),
        ]
    }
}

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
            ("Ta\nuri app", "tauri app"),
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

        let textAuthoritative = StructuredTranscript(
            text: "Mesh is running Quan and Quan is doing the heavy judging.",
            sentences: [
                TranscriptSentence(
                    text: "Mesh is running Quan and Quan is doing the heavy judging.",
                    start: 0.0,
                    end: 4.0,
                    words: [
                        TranscriptWord(text: "Mesh", start: 0.0, end: 0.2),
                        TranscriptWord(text: "is", start: 0.2, end: 0.4),
                        TranscriptWord(text: "runningQuan", start: 0.4, end: 1.0),
                        TranscriptWord(text: "andQuan", start: 1.2, end: 1.8),
                        TranscriptWord(text: "is", start: 1.9, end: 2.1),
                        TranscriptWord(text: "doing", start: 2.1, end: 2.4),
                        TranscriptWord(text: "the", start: 2.4, end: 2.6),
                        TranscriptWord(text: "heavy", start: 2.6, end: 3.0),
                        TranscriptWord(text: "judging.", start: 3.0, end: 4.0),
                    ]
                ),
            ]
        )
        let authoritativeCleaned = TranscriptPostProcessor.clean(textAuthoritative)
        expect(
            authoritativeCleaned == "Mesh is running qwen and qwen is doing the heavy judging.",
            "Expected sentence text to remain authoritative over glued timing words, got `\(authoritativeCleaned)`"
        )

        print("TranscriptPostProcessor tests passed")
    }
}
