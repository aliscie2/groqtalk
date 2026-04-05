import AVFoundation
import Foundation

final class AudioPlayer: @unchecked Sendable {

    private var audioPlayer: AVAudioPlayer?
    private let lock = NSLock()
    private(set) var cancelled = false

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
                    while player.isPlaying {
                        lock.lock()
                        let c = cancelled
                        lock.unlock()
                        if c { player.stop(); break }
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

    func reset() {
        lock.lock()
        cancelled = false
        lock.unlock()
    }
}
