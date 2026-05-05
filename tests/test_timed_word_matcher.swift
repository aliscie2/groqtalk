import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct TimedWordMatcherTests {
    static func main() {
        let transcriptWords = [
            TranscriptWord(text: "beta", start: 0.00, end: 0.34),
            TranscriptWord(text: "gamma", start: 0.35, end: 0.78),
        ]

        let aligned = TimedWordMatcher.buildAlignedWords(
            transcriptWords: transcriptWords,
            spokenText: "beta gamma",
            displayText: "alpha beta gamma",
            startWordIndex: 1
        )

        expect(
            aligned.map(\.wordIndex) == [1, 2],
            "Expected spoken words to map onto the visible display-word indices"
        )

        expect(
            TimedWordMatcher.wordIndex(at: 0.10, in: aligned) == 1,
            "Expected early playback to resolve to the first aligned word"
        )

        expect(
            TimedWordMatcher.wordIndex(at: 0.70, in: aligned) == 2,
            "Expected later playback to resolve to the second aligned word"
        )

        let tracker = LiveWordTracker(startWordIndex: 1, playableWordCount: 2, startTime: 0)
        tracker.applyExactWords(aligned)

        expect(
            tracker.currentWordIndex(currentTime: 0.05, duration: 1.0) == 1,
            "Expected tracker to prefer exact timings at playback start"
        )

        expect(
            tracker.currentWordIndex(currentTime: 0.40, duration: 1.0) == 1,
            "Expected visual lag to avoid highlighting the next word before it is spoken"
        )

        expect(
            tracker.currentWordIndex(currentTime: 0.70, duration: 1.0) == 2,
            "Expected tracker to advance once exact timing plus visual lag has passed"
        )

        expect(
            tracker.playbackTime(forWordIndex: 2, duration: 1.0) == 0.35,
            "Expected tracker to expose exact playback time for in-chunk seeking"
        )

        let estimatedTracker = LiveWordTracker(startWordIndex: 4, playableWordCount: 4, startTime: 0)
        expect(
            estimatedTracker.currentWordIndex(currentTime: 4.0, duration: 8.0) == nil,
            "Expected live highlighting to wait for exact alignment instead of using fake estimated timings"
        )

        expect(
            abs((estimatedTracker.playbackTime(forWordIndex: 6, duration: 8.0) ?? -1) - 4.0) < 0.001,
            "Expected tracker to estimate a seek time before exact timings arrive"
        )

        expect(
            estimatedTracker.playbackTime(forWordIndex: 9, duration: 8.0) == nil,
            "Expected out-of-range word seeks to fail cleanly"
        )

        print("TimedWordMatcher tests passed")
    }
}
