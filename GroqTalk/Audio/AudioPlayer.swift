import AVFoundation
import Foundation

final class AudioPlayer: @unchecked Sendable {

    private var audioPlayer: AVAudioPlayer?
    private let lock = NSLock()
    private(set) var cancelled = false
    private(set) var paused = false

    /// Current playback position of the active chunk (seconds). 0 when idle.
    var currentTime: TimeInterval { audioPlayer?.currentTime ?? 0 }

    func play(data: Data, rate: Float = 1.0) async {
        lock.lock()
        if cancelled { lock.unlock(); return }
        lock.unlock()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(); return }
                lock.unlock()

                do {
                    let player = try AVAudioPlayer(data: data)
                    player.enableRate = true
                    player.rate = rate

                    lock.lock()
                    audioPlayer = player
                    lock.unlock()

                    player.play()
                    while player.isPlaying || self.paused {
                        lock.lock()
                        let c = cancelled
                        let p = paused
                        lock.unlock()
                        if c { player.stop(); break }
                        if p && player.isPlaying { player.pause() }
                        Thread.sleep(forTimeInterval: 0.05)
                    }
                } catch {
                    Log.error("[PLAYER] \(error)")
                }
                continuation.resume()
            }
        }
    }

    func stop() {
        lock.lock()
        cancelled = true
        audioPlayer?.stop()
        audioPlayer = nil
        lock.unlock()
    }

    func togglePause() {
        lock.lock()
        if paused {
            paused = false
            audioPlayer?.play()
            Log.info("[PLAYER] resumed")
        } else {
            paused = true
            Log.info("[PLAYER] paused")
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        cancelled = false
        paused = false
        lock.unlock()
    }
}
