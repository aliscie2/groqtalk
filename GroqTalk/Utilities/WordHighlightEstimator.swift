import Foundation

enum WordHighlightEstimator {
    static func estimatedWordIndex(
        startWordIndex: Int,
        playableWordCount: Int,
        currentTime: TimeInterval,
        duration: TimeInterval,
        startTime: TimeInterval
    ) -> Int? {
        guard playableWordCount > 0 else { return nil }

        let effectiveDuration = max(0.001, duration - startTime)
        let elapsed = max(0, currentTime - startTime)
        let progress = min(max(elapsed / effectiveDuration, 0), 0.999_999)
        let relativeWord = min(
            playableWordCount - 1,
            Int(progress * Double(playableWordCount))
        )
        return startWordIndex + relativeWord
    }
}
