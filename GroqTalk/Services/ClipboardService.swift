import AppKit
import CoreGraphics

enum ClipboardService {

    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func read() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    static func paste() {
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    static func getSelectedText() -> String {
        // Try Accessibility API first
        if AccessibilityChecker.isTrusted() {
            if let text = getSelectedTextViaAX(), !text.isEmpty {
                Log.debug("[get_selected_text] AX got \(text.count) chars")
                return text
            }
        } else {
            Log.info("[get_selected_text] no Accessibility — cannot simulate Cmd+C")
        }

        // Fallback: simulate Cmd+C
        let prev = read()
        write("")

        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 0x08, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        usleep(150_000)
        let text = read()
        if text.isEmpty { write(prev) }
        Log.debug("[get_selected_text] Cmd+C fallback got \(text.count) chars")
        return text
    }

    private static func getSelectedTextViaAX() -> String? {
        let sys = AXUIElementCreateSystemWide()
        var focusedValue: AnyObject?
        let err1 = AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedValue)
        guard err1 == .success, let focused = focusedValue else { return nil }

        var selectedValue: AnyObject?
        let err2 = AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedValue)
        guard err2 == .success, let text = selectedValue as? String else { return nil }
        return text
    }
}
