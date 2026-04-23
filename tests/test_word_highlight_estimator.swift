import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct WordHighlightEstimatorTests {
    static func main() {
        expect(
            WordHighlightEstimator.estimatedWordIndex(
                startWordIndex: 0,
                playableWordCount: 5,
                currentTime: 0,
                duration: 10,
                startTime: 0
            ) == 0,
            "Expected playback start to highlight the first word"
        )

        expect(
            WordHighlightEstimator.estimatedWordIndex(
                startWordIndex: 3,
                playableWordCount: 4,
                currentTime: 3,
                duration: 8,
                startTime: 2
            ) == 3,
            "Expected jumped playback to respect the requested start word"
        )

        expect(
            WordHighlightEstimator.estimatedWordIndex(
                startWordIndex: 3,
                playableWordCount: 4,
                currentTime: 5,
                duration: 8,
                startTime: 2
            ) == 5,
            "Expected mid-playback progress to advance through the playable words"
        )

        expect(
            WordHighlightEstimator.estimatedWordIndex(
                startWordIndex: 3,
                playableWordCount: 4,
                currentTime: 8,
                duration: 8,
                startTime: 2
            ) == 6,
            "Expected playback end to clamp to the last playable word"
        )

        expect(
            WordHighlightEstimator.estimatedWordIndex(
                startWordIndex: 0,
                playableWordCount: 0,
                currentTime: 1,
                duration: 5,
                startTime: 0
            ) == nil,
            "Expected zero playable words to produce no highlight"
        )

        print("WordHighlightEstimator tests passed")
    }
}
