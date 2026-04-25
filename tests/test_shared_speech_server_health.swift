import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct SharedSpeechServerHealthTests {
    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_000)

        var timeoutState = SharedSpeechServerHealthState()
        expect(
            timeoutState.recordTimeout(phase: .livePartial, now: t0) == nil,
            "Expected one live timeout to be tolerated"
        )
        expect(
            timeoutState.recordTimeout(phase: .livePartial, now: t0.addingTimeInterval(5)) == nil,
            "Expected two live timeouts to be tolerated"
        )
        let timeoutDecision = timeoutState.recordTimeout(
            phase: .livePartial,
            now: t0.addingTimeInterval(10)
        )
        expect(
            timeoutDecision == nil,
            "Expected repeated live timeouts to skip recovery during active dictation"
        )
        expect(
            timeoutState.consecutiveLiveTimeouts == 3,
            "Expected live timeout counters to still be tracked"
        )

        var finalTimeoutState = SharedSpeechServerHealthState()
        let finalTimeoutDecision = finalTimeoutState.recordTimeout(phase: .finalPass, now: t0)
        expect(
            finalTimeoutDecision?.reason.contains("timed out during a final STT run") == true,
            "Expected a final timeout to request immediate shared-server recovery"
        )

        var slowFinalState = SharedSpeechServerHealthState()
        expect(
            slowFinalState.recordSuccess(duration: 1.7, phase: .finalPass, now: t0) == nil,
            "Expected one mildly slow final pass to be tolerated"
        )
        let slowFinalDecision = slowFinalState.recordSuccess(
            duration: 1.9,
            phase: .finalPass,
            now: t0.addingTimeInterval(25)
        )
        expect(
            slowFinalDecision?.reason.contains("slow final STT runs") == true,
            "Expected repeated slow final passes to trigger recovery"
        )

        var hardSlowState = SharedSpeechServerHealthState()
        let hardSlowDecision = hardSlowState.recordSuccess(duration: 5.2, phase: .finalPass, now: t0)
        expect(
            hardSlowDecision?.reason.contains("5.20s") == true,
            "Expected a very slow final pass to trigger immediate recovery"
        )

        var coldStartState = SharedSpeechServerHealthState()
        coldStartState.noteRestart(now: t0)
        expect(
            coldStartState.recordSuccess(duration: 5.2, phase: .finalPass, now: t0.addingTimeInterval(5)) == nil,
            "Expected cooldown to suppress cold-start final recovery"
        )
        let coldStartReleased = coldStartState.recordSuccess(
            duration: 5.2,
            phase: .finalPass,
            now: t0.addingTimeInterval(25)
        )
        expect(
            coldStartReleased?.reason.contains("5.20s") == true,
            "Expected hard-slow final recovery after startup cooldown"
        )

        var liveDoesNotCooldownState = SharedSpeechServerHealthState()
        _ = liveDoesNotCooldownState.recordTimeout(phase: .livePartial, now: t0)
        _ = liveDoesNotCooldownState.recordTimeout(phase: .livePartial, now: t0.addingTimeInterval(1))
        _ = liveDoesNotCooldownState.recordTimeout(phase: .livePartial, now: t0.addingTimeInterval(2))
        let finalAfterLiveTimeouts = liveDoesNotCooldownState.recordTimeout(
            phase: .finalPass,
            now: t0.addingTimeInterval(5)
        )
        expect(
            finalAfterLiveTimeouts?.reason.contains("final STT run") == true,
            "Expected live timeouts not to consume the final-pass recovery window"
        )

        var cooldownState = SharedSpeechServerHealthState()
        _ = cooldownState.recordTimeout(phase: .finalPass, now: t0)
        let cooldownSuppressed = cooldownState.recordTimeout(
            phase: .finalPass,
            now: t0.addingTimeInterval(5)
        )
        expect(
            cooldownSuppressed == nil,
            "Expected cooldown to suppress repeated recovery requests"
        )
        let cooldownReleased = cooldownState.recordTimeout(
            phase: .finalPass,
            now: t0.addingTimeInterval(25)
        )
        expect(
            cooldownReleased?.reason.contains("final STT run") == true,
            "Expected recovery to become available again after cooldown"
        )

        var slowLiveState = SharedSpeechServerHealthState()
        expect(
            slowLiveState.recordSuccess(duration: 1.1, phase: .livePartial, now: t0) == nil,
            "Expected one slow live partial to be tolerated"
        )
        expect(
            slowLiveState.recordSuccess(duration: 1.2, phase: .livePartial, now: t0.addingTimeInterval(25)) == nil,
            "Expected two slow live partials to be tolerated"
        )
        let slowLiveDecision = slowLiveState.recordSuccess(
            duration: 1.3,
            phase: .livePartial,
            now: t0.addingTimeInterval(50)
        )
        expect(
            slowLiveDecision == nil,
            "Expected repeated slow live partials not to restart during active dictation"
        )
        expect(
            slowLiveState.consecutiveSlowLive == 3,
            "Expected slow live counters to still be tracked"
        )

        print("SharedSpeechServerHealth tests passed")
    }
}
