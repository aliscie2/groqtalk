import Foundation

struct ConfigManager {
    static let sampleRate = 16_000
    static let silenceThreshold: Float = 0.003
    static let silenceAboveRatio: Float = 0.02
}

enum Log {
    static func debug(_ message: String) {}
    static func info(_ message: String) {}
    static func error(_ message: String) {
        fatalError(message)
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct AudioPlayerLifecycleTests {
    static func main() async {
        let player = AudioPlayer()
        let wav = AudioProcessor.silentWAV(seconds: 0.25, sampleRate: 16_000)

        for _ in 0..<12 {
            player.reset()
            let playback = Task {
                await player.play(data: wav, rate: 1.0)
            }
            try? await Task.sleep(for: .milliseconds(15))
            player.stop()
            await playback.value

            expect(player.cancelled, "stop() should mark playback as cancelled")
            expect(player.duration == 0, "stopped playback should release the active AVAudioPlayer")
        }

        player.reset()
        var progressCount = 0
        await player.play(data: wav, rate: 1.0) { _ in
            progressCount += 1
        }

        expect(!player.cancelled, "natural playback completion should not poison the next session")
        expect(player.duration == 0, "finished playback should release the active AVAudioPlayer")
        expect(progressCount > 0, "playback should emit progress snapshots while active")

        print("AudioPlayer lifecycle tests passed")
    }
}
