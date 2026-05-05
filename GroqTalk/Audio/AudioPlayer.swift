import AVFoundation
import Foundation

final class AudioPlayer: @unchecked Sendable {
    struct PlaybackSnapshot {
        let currentTime: TimeInterval
        let duration: TimeInterval
        let paused: Bool
    }

    // AVAudioPlayer posts completion work back through the main run loop. Keep
    // every AVAudioPlayer touch on the main thread so stop/dealloc cannot race
    // with Apple's private finishedPlaying callback.
    private var audioPlayer: AVAudioPlayer?
    private var playbackID = 0
    private let lock = NSLock()
    private var isCancelled = false
    private var isPaused = false
    private var lastCurrentTime: TimeInterval = 0
    private var lastDuration: TimeInterval = 0

    /// Current playback position of the active chunk (seconds). 0 when idle.
    var currentTime: TimeInterval {
        if Thread.isMainThread, let audioPlayer {
            return audioPlayer.currentTime
        }
        return lockedSnapshot().currentTime
    }

    var duration: TimeInterval {
        if Thread.isMainThread, let audioPlayer {
            return audioPlayer.duration
        }
        return lockedSnapshot().duration
    }

    var cancelled: Bool { lockedFlags().cancelled }
    var paused: Bool { lockedFlags().paused }

    func play(
        data: Data,
        rate: Float = 1.0,
        startAt: TimeInterval = 0,
        endAt: TimeInterval? = nil,
        onProgress: ((PlaybackSnapshot) -> Void)? = nil
    ) async {
        guard let id = await MainActor.run(body: {
            self.startPlaybackOnMain(data: data, rate: rate, startAt: startAt)
        }) else {
            return
        }

        let cutoff = endAt.map { max(startAt, $0) }
        while true {
            if Task.isCancelled {
                await MainActor.run { self.clearPlaybackOnMain(id: id, stopFirst: true) }
                break
            }

            let result = await MainActor.run {
                self.pollPlaybackOnMain(id: id, cutoff: cutoff)
            }

            if let snapshot = result.snapshot {
                onProgress?(snapshot)
            }
            if result.finished {
                break
            }

            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func stop() {
        setFlags(cancelled: true)
        onMainSync {
            playbackID &+= 1
            clearPlaybackOnMain(id: nil, stopFirst: true)
        }
    }

    func togglePause() {
        let nowPaused: Bool = lock.withLock {
            isPaused.toggle()
            return isPaused
        }

        onMainSync {
            if nowPaused {
                audioPlayer?.pause()
                Log.info("[PLAYER] paused")
            } else {
                audioPlayer?.play()
                Log.info("[PLAYER] resumed")
            }
        }
    }

    func reset() {
        setFlags(cancelled: false, paused: false)
    }

    /// Seek within the currently-playing chunk. Returns true if the seek
    /// landed (i.e. there was an active player); false means the caller
    /// needs to spin up a fresh play() with startAt.
    @discardableResult
    func seek(to time: TimeInterval) -> Bool {
        onMainSync {
            guard let player = audioPlayer else { return false }
            player.currentTime = max(0, min(time, player.duration))
            rememberSnapshot(currentTime: player.currentTime, duration: player.duration)
            return true
        }
    }

    private func startPlaybackOnMain(data: Data, rate: Float, startAt: TimeInterval) -> Int? {
        logIfOffMain(#function)
        guard !cancelled else { return nil }

        do {
            let player = try AVAudioPlayer(data: data)
            player.enableRate = true
            player.rate = rate
            if startAt > 0 {
                player.currentTime = max(0, min(startAt, player.duration))
            }

            playbackID &+= 1
            let id = playbackID
            audioPlayer?.stop()
            audioPlayer = player
            rememberSnapshot(currentTime: player.currentTime, duration: player.duration)
            player.play()
            return id
        } catch {
            Log.error("[PLAYER] \(error)")
            return nil
        }
    }

    private func pollPlaybackOnMain(
        id: Int,
        cutoff: TimeInterval?
    ) -> (snapshot: PlaybackSnapshot?, finished: Bool) {
        logIfOffMain(#function)
        guard playbackID == id, let player = audioPlayer else {
            return (nil, true)
        }

        let flags = lockedFlags()
        if flags.cancelled {
            clearPlaybackOnMain(id: id, stopFirst: true)
            return (nil, true)
        }

        let snapshot = PlaybackSnapshot(
            currentTime: player.currentTime,
            duration: player.duration,
            paused: flags.paused
        )
        rememberSnapshot(currentTime: snapshot.currentTime, duration: snapshot.duration)

        if let cutoff, player.currentTime >= cutoff {
            clearPlaybackOnMain(id: id, stopFirst: true)
            return (snapshot, true)
        }

        if flags.paused {
            if player.isPlaying { player.pause() }
            return (snapshot, false)
        }

        if !player.isPlaying {
            clearPlaybackOnMain(id: id, stopFirst: false)
            return (snapshot, true)
        }

        return (snapshot, false)
    }

    private func clearPlaybackOnMain(id: Int?, stopFirst: Bool) {
        logIfOffMain(#function)
        if let id, playbackID != id { return }
        if stopFirst {
            audioPlayer?.stop()
        }
        audioPlayer = nil
        rememberSnapshot(currentTime: 0, duration: 0)
    }

    private func lockedFlags() -> (cancelled: Bool, paused: Bool) {
        lock.withLock { (isCancelled, isPaused) }
    }

    private func setFlags(cancelled: Bool? = nil, paused: Bool? = nil) {
        lock.withLock {
            if let cancelled { isCancelled = cancelled }
            if let paused { isPaused = paused }
        }
    }

    private func lockedSnapshot() -> PlaybackSnapshot {
        lock.withLock {
            PlaybackSnapshot(
                currentTime: lastCurrentTime,
                duration: lastDuration,
                paused: isPaused
            )
        }
    }

    private func rememberSnapshot(currentTime: TimeInterval, duration: TimeInterval) {
        lock.withLock {
            lastCurrentTime = currentTime
            lastDuration = duration
        }
    }

    private func onMainSync<T>(_ work: () -> T) -> T {
        if Thread.isMainThread {
            return work()
        }
        return DispatchQueue.main.sync(execute: work)
    }

    private func logIfOffMain(_ function: StaticString) {
        if !Thread.isMainThread {
            Log.error("[PLAYER] \(function) touched AVAudioPlayer off the main thread")
        }
    }
}

private extension NSLock {
    func withLock<T>(_ work: () -> T) -> T {
        lock()
        defer { unlock() }
        return work()
    }
}
