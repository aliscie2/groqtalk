import AVFoundation
import Foundation

final class AudioPlayer: @unchecked Sendable {
    struct PlaybackSnapshot {
        let currentTime: TimeInterval
        let duration: TimeInterval
        let paused: Bool
    }

    private var audioPlayer: AVAudioPlayer?
    private let lock = NSLock()
    private(set) var cancelled = false
    private(set) var paused = false

    /// Current playback position of the active chunk (seconds). 0 when idle.
    var currentTime: TimeInterval { audioPlayer?.currentTime ?? 0 }
    var duration: TimeInterval { audioPlayer?.duration ?? 0 }

    func play(
        data: Data,
        rate: Float = 1.0,
        startAt: TimeInterval = 0,
        endAt: TimeInterval? = nil,
        onProgress: ((PlaybackSnapshot) -> Void)? = nil
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                lock.lock()
                if cancelled { lock.unlock(); continuation.resume(); return }
                lock.unlock()

                do {
                    let player = try AVAudioPlayer(data: data)
                    player.enableRate = true
                    player.rate = rate
                    if startAt > 0 { player.currentTime = startAt }

                    lock.lock()
                    audioPlayer = player
                    lock.unlock()

                    player.play()
                    let cutoff = endAt.map { max(startAt, $0) }
                    while player.isPlaying || self.paused {
                        lock.lock()
                        let c = cancelled
                        let p = paused
                        lock.unlock()
                        if c { player.stop(); break }
                        if let cutoff, player.currentTime >= cutoff {
                            player.stop()
                            break
                        }
                        onProgress?(PlaybackSnapshot(
                            currentTime: player.currentTime,
                            duration: player.duration,
                            paused: p
                        ))
                        if p && player.isPlaying { player.pause() }
                        Thread.sleep(forTimeInterval: 0.05)
                    }

                    lock.lock()
                    if audioPlayer === player {
                        audioPlayer = nil
                    }
                    lock.unlock()
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

    /// Seek within the currently-playing chunk. Returns true if the seek
    /// landed (i.e. there was an active player); false means the caller
    /// needs to spin up a fresh play() with startAt.
    @discardableResult
    func seek(to time: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let p = audioPlayer else { return false }
        p.currentTime = max(0, time)
        return true
    }
}
