import Carbon
import Foundation

/// Detects when macOS "Secure Input" mode is active — the condition that
/// silently gags every CGEventTap in the system, including our hotkey tap.
///
/// Secure Input is turned on automatically whenever any NSSecureTextField
/// has keyboard focus (loginwindow, password prompts, 1Password auto-type,
/// Terminal's "Secure Keyboard Entry" toggle, etc). There is NO public
/// callback; the only way to detect it is to poll `IsSecureEventInputEnabled()`.
///
/// This monitor logs transitions so future "why is my hotkey dead?" debugging
/// is 5 seconds instead of 4 hours. It is intentionally small and stateless —
/// it doesn't try to do anything about the condition, just makes it visible.
final class SecureInputMonitor {

    static let shared = SecureInputMonitor()

    private var timer: Timer?
    private var lastState: Bool = false
    private var onChange: ((Bool) -> Void)?

    private init() {}

    /// Start polling. `onChange` fires on the main queue whenever the state
    /// flips, so callers can update menu-bar UI.
    func start(onChange: @escaping (Bool) -> Void) {
        self.onChange = onChange
        lastState = IsSecureEventInputEnabled()
        Log.info("[SECURE-INPUT] initial state: \(lastState)")
        onChange(lastState)

        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        if let t = timer { RunLoop.main.add(t, forMode: .common) }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = IsSecureEventInputEnabled()
        guard now != lastState else { return }
        lastState = now
        Log.info("[SECURE-INPUT] transitioned to \(now) — hotkeys \(now ? "BLOCKED by system" : "live again")")
        onChange?(now)
    }
}
