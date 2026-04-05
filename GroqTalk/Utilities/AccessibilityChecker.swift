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
            // Reset old permissions for this bundle ID so macOS prompts fresh
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            task.arguments = ["reset", "Accessibility", "com.groqtalk.app"]
            try? task.run()
            task.waitUntilExit()
            Log.info("Reset old Accessibility permissions")

            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(opts)
            Log.info("Prompted user for Accessibility permission")
        }
    }
}
