import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct LiveTranscriptAssemblerTests {
    static func main() {
        var assembler = LiveTranscriptAssembler(
            unstableTailSeconds: 0.5,
            fallbackTentativeWordCount: 2,
            contextWordLimit: 8
        )

        let first = StructuredTranscript(
            text: "hello there general kenobi",
            sentences: [
                TranscriptSentence(
                    text: "hello there general kenobi",
                    start: 0.0,
                    end: 1.6,
                    words: [
                        TranscriptWord(text: "hello", start: 0.00, end: 0.20),
                        TranscriptWord(text: "there", start: 0.24, end: 0.44),
                        TranscriptWord(text: "general", start: 0.48, end: 0.82),
                        TranscriptWord(text: "kenobi", start: 1.05, end: 1.42),
                    ]
                )
            ]
        )

        let firstSnapshot = assembler.consume(first)
        expect(
            firstSnapshot == LiveCaptionSnapshot(
                committedText: "hello there general",
                tentativeText: "kenobi"
            ),
            "Expected the early words to stabilize while the tail stays tentative"
        )

        let second = StructuredTranscript(
            text: "there general kenobi now",
            sentences: [
                TranscriptSentence(
                    text: "there general kenobi now",
                    start: 0.0,
                    end: 1.6,
                    words: [
                        TranscriptWord(text: "there", start: 0.00, end: 0.18),
                        TranscriptWord(text: "general", start: 0.22, end: 0.52),
                        TranscriptWord(text: "kenobi", start: 0.56, end: 0.90),
                        TranscriptWord(text: "now", start: 1.08, end: 1.28),
                    ]
                )
            ]
        )

        let secondSnapshot = assembler.consume(second)
        expect(
            secondSnapshot == LiveCaptionSnapshot(
                committedText: "hello there general kenobi",
                tentativeText: "now"
            ),
            "Expected overlapping rolling windows to merge without rewriting the whole caption"
        )

        var fallbackAssembler = LiveTranscriptAssembler(
            unstableTailSeconds: 0.5,
            fallbackTentativeWordCount: 2,
            contextWordLimit: 8
        )
        let fallback = StructuredTranscript(text: "alpha beta gamma delta", sentences: [])
        let fallbackSnapshot = fallbackAssembler.consume(fallback)
        expect(
            fallbackSnapshot == LiveCaptionSnapshot(
                committedText: "alpha beta",
                tentativeText: "gamma delta"
            ),
            "Expected no-timing transcripts to keep a short tentative tail instead of replacing everything"
        )

        print("LiveTranscriptAssembler tests passed")
    }
}
