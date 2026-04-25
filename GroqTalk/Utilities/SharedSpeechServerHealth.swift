import Foundation

struct SharedSpeechServerHealthState {
    enum Phase {
        case livePartial
        case finalPass
    }

    struct Decision: Equatable {
        let reason: String
    }

    var slowLiveThreshold: TimeInterval = 1.0
    var slowFinalThreshold: TimeInterval = 1.5
    var hardSlowFinalThreshold: TimeInterval = 4.0
    var slowFinalRestartCount: Int = 2
    var restartCooldown: TimeInterval = 20.0

    private(set) var consecutiveSlowLive = 0
    private(set) var consecutiveSlowFinal = 0
    private(set) var consecutiveLiveTimeouts = 0
    private(set) var lastRestartAt: Date?

    mutating func recordSuccess(
        duration: TimeInterval,
        phase: Phase,
        now: Date = Date()
    ) -> Decision? {
        switch phase {
        case .livePartial:
            consecutiveLiveTimeouts = 0
            if duration >= slowLiveThreshold {
                consecutiveSlowLive += 1
            } else {
                consecutiveSlowLive = 0
            }
        case .finalPass:
            consecutiveSlowLive = 0
            consecutiveLiveTimeouts = 0
            if duration >= hardSlowFinalThreshold {
                return makeDecision(
                    reason: "shared 8723 server final STT took \(formatted(duration))",
                    now: now
                )
            }
            if duration >= slowFinalThreshold {
                consecutiveSlowFinal += 1
            } else {
                consecutiveSlowFinal = 0
            }
            if consecutiveSlowFinal >= slowFinalRestartCount {
                return makeDecision(
                    reason: "shared 8723 server produced \(consecutiveSlowFinal) slow final STT runs (latest \(formatted(duration)))",
                    now: now
                )
            }
        }
        return nil
    }

    mutating func recordTimeout(
        phase: Phase,
        now: Date = Date()
    ) -> Decision? {
        switch phase {
        case .livePartial:
            consecutiveLiveTimeouts += 1
            return nil
        case .finalPass:
            return makeDecision(
                reason: "shared 8723 server timed out during a final STT run",
                now: now
            )
        }
    }

    mutating func noteRestart(now: Date = Date()) {
        resetCounters()
        lastRestartAt = now
    }

    private mutating func makeDecision(
        reason: String,
        now: Date
    ) -> Decision? {
        if let lastRestartAt, now.timeIntervalSince(lastRestartAt) < restartCooldown {
            return nil
        }
        resetCounters()
        lastRestartAt = now
        return Decision(reason: reason)
    }

    private mutating func resetCounters() {
        consecutiveSlowLive = 0
        consecutiveSlowFinal = 0
        consecutiveLiveTimeouts = 0
    }

    private func formatted(_ duration: TimeInterval) -> String {
        String(format: "%.2fs", duration)
    }
}

enum SharedSpeechServerHealth {
    private static let queue = DispatchQueue(label: "groqtalk.shared-speech-health")
    private static var state = SharedSpeechServerHealthState()

    static func recordSuccess(duration: TimeInterval, phase: SharedSpeechServerHealthState.Phase) -> String? {
        queue.sync {
            state.recordSuccess(duration: duration, phase: phase)?.reason
        }
    }

    static func recordTimeout(phase: SharedSpeechServerHealthState.Phase) -> String? {
        queue.sync {
            state.recordTimeout(phase: phase)?.reason
        }
    }

    static func noteRestart() {
        queue.sync {
            state.noteRestart()
        }
    }
}
