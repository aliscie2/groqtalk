import Foundation

/// Tracks last-use timestamps per local server and schedules idle shutdown / on-demand reload.
///
/// Why: On 16 GB Macs, mlx_audio (Kokoro) + whisper.cpp can hold ~1-2 GB resident
/// even when idle. Hot-swap unloads them after N seconds of inactivity and reloads
/// on next use.
///
/// Handlers are injected by AppDelegate at startup so this module stays
/// independent of the concrete Process plumbing.
enum ModelLifecycle {

    // MARK: - Config

    /// Idle seconds before shutdown. 0 disables hot-swap entirely.
    static var idleSeconds: Int { ConfigManager.idleUnloadSeconds }

    // MARK: - Injected handlers (wired by AppDelegate)

    static var whisperStart: (() -> Void)?
    static var whisperStop:  (() -> Void)?
    static var kokoroStart:  (() -> Void)?
    static var kokoroStop:   (() -> Void)?

    // MARK: - Internal state

    /// Serial queue guards state mutations; handlers hop to main for UI/Process work.
    private static let queue = DispatchQueue(label: "groqtalk.modellifecycle")

    private static var whisperRunning = true
    private static var kokoroRunning  = true

    private static var whisperTimer: DispatchSourceTimer?
    private static var kokoroTimer:  DispatchSourceTimer?

    // MARK: - Public API

    /// Call before every STT request. Reloads whisper if it was unloaded,
    /// and resets the idle countdown.
    static func touchWhisper() {
        queue.async {
            if !whisperRunning {
                Log.info("[LIFECYCLE] touchWhisper — reloading (was idle)")
                whisperRunning = true
                DispatchQueue.main.async { whisperStart?() }
            }
            scheduleWhisperShutdown()
        }
    }

    /// Call before every TTS request. Reloads Kokoro if it was unloaded,
    /// and resets the idle countdown.
    static func touchKokoro() {
        queue.async {
            if !kokoroRunning {
                Log.info("[LIFECYCLE] touchKokoro — reloading (was idle)")
                kokoroRunning = true
                DispatchQueue.main.async { kokoroStart?() }
            }
            scheduleKokoroShutdown()
        }
    }

    /// Mark that servers were started externally (e.g. at app launch).
    /// Starts idle countdowns so they auto-unload if never used.
    static func markWhisperStarted() {
        queue.async {
            whisperRunning = true
            scheduleWhisperShutdown()
        }
    }

    static func markKokoroStarted() {
        queue.async {
            kokoroRunning = true
            scheduleKokoroShutdown()
        }
    }

    // MARK: - Shutdown scheduling

    private static func scheduleWhisperShutdown() {
        whisperTimer?.cancel()
        whisperTimer = nil

        let seconds = idleSeconds
        guard seconds > 0 else { return }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(seconds))
        t.setEventHandler {
            guard whisperRunning else { return }
            Log.info("[LIFECYCLE] whisper idle \(seconds)s — unloading")
            whisperRunning = false
            DispatchQueue.main.async { whisperStop?() }
        }
        t.resume()
        whisperTimer = t
    }

    private static func scheduleKokoroShutdown() {
        kokoroTimer?.cancel()
        kokoroTimer = nil

        let seconds = idleSeconds
        guard seconds > 0 else { return }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .seconds(seconds))
        t.setEventHandler {
            guard kokoroRunning else { return }
            Log.info("[LIFECYCLE] kokoro idle \(seconds)s — unloading")
            kokoroRunning = false
            DispatchQueue.main.async { kokoroStop?() }
        }
        t.resume()
        kokoroTimer = t
    }
}
