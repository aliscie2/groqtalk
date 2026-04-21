import ApplicationServices
import CoreGraphics
import Foundation

enum AccessibilityChecker {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func checkAndPrompt() {
        // macOS 10.15+ requires TWO separate TCC services for a CGEventTap to
        // actually receive events:
        //   1. Accessibility — lets the process be a trusted event observer.
        //   2. Input Monitoring — lets it actually read keystrokes.
        // If either is missing, CGEvent.tapCreate still returns non-nil (so
        // the tap "installs") but NO events are ever delivered. This is the
        // single worst footgun on macOS: you think everything is fine because
        // the tap installed, but the hotkey silently does nothing.
        let axTrusted = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        Log.info("Accessibility trusted: \(axTrusted) | Input Monitoring: \(inputMonitoring)")

        if !axTrusted {
            // Do NOT call `tccutil reset` here — it wipes the user's grant and
            // creates an infinite re-grant loop across relaunches.
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            Log.info("Prompted user for Accessibility — grant in System Settings, then relaunch")
        }

        if !inputMonitoring {
            // Triggers the first-launch Input Monitoring dialog. On subsequent
            // launches after the user has either granted or denied, this is a
            // no-op (no dialog), so it's safe to call every launch.
            _ = CGRequestListenEventAccess()
            Log.info("Requested Input Monitoring — grant in System Settings → Privacy & Security → Input Monitoring, then relaunch")
        }
    }
}
