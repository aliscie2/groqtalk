import ApplicationServices
import Foundation

enum AccessibilityChecker {
    static func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    static func checkAndPrompt() {
        let trusted = AXIsProcessTrusted()
        Log.info("Accessibility trusted: \(trusted)")
        if !trusted {
            // Do NOT call `tccutil reset` here — it wipes the user's grant and
            // creates an infinite re-grant loop across relaunches. TCC persists
            // correctly as long as the app is signed with a stable identity
            // (see build.sh + scripts/create-signing-cert.sh).
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            Log.info("Prompted user for Accessibility permission — grant it in System Settings, then relaunch")
        }
    }
}
