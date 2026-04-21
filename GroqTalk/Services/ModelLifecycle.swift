import Foundation

/// Idle-shutdown for the local Kokoro / Parakeet server (both hosted by
/// one mlx_audio.server process). On 16 GB Macs the resident model can
/// pin ~1-2 GB; hot-swap unloads it after N seconds of inactivity and
/// reloads on next use. Default idleSeconds = 0 disables hot-swap.
enum ModelLifecycle {
    static var idleSeconds: Int { ConfigManager.idleUnloadSeconds }

    // Handlers are injected by AppDelegate so this module stays free of
    // Process plumbing.
    static var kokoroStart: (() -> Void)?
    static var kokoroStop:  (() -> Void)?

    private static let queue = DispatchQueue(label: "groqtalk.modellifecycle")
    private static var kokoroRunning = true
    private static var kokoroTimer:  DispatchSourceTimer?

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

    static func markKokoroStarted() {
        queue.async { kokoroRunning = true; scheduleKokoroShutdown() }
    }

    private static func scheduleKokoroShutdown() {
        kokoroTimer?.cancel(); kokoroTimer = nil
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
