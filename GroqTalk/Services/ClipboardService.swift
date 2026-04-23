import AppKit
import ApplicationServices
import CoreGraphics

enum ClipboardService {
    struct InsertionTarget {
        let processIdentifier: pid_t
        let appName: String
        let role: String
        let subrole: String
        fileprivate let element: AXUIElement?

        var isCurrentApp: Bool {
            processIdentifier == NSRunningApplication.current.processIdentifier
        }

        var summary: String {
            "\(appName) pid=\(processIdentifier) role=\(role) subrole=\(subrole)"
        }
    }

    private struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    enum InsertionStep: Equatable {
        case restoreCapturedFocus
        case preservedClipboardPaste
        case unicodeKeyboardFallback
    }

    static func insertionPlan(hasCapturedTarget: Bool) -> [InsertionStep] {
        var steps: [InsertionStep] = []
        if hasCapturedTarget {
            steps.append(.restoreCapturedFocus)
        }
        steps.append(.preservedClipboardPaste)
        steps.append(.unicodeKeyboardFallback)
        return steps
    }

    static func write(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func read() -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }

    @discardableResult
    static func paste() -> Bool {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0x09, keyDown: false) else {
            return false
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }

    @discardableResult
    static func insertText(_ text: String, target: InsertionTarget? = nil) -> Bool {
        guard !text.isEmpty else { return false }

        for step in insertionPlan(hasCapturedTarget: target != nil) {
            switch step {
            case .restoreCapturedFocus:
                if let target {
                    Log.debug("[INSERT] using captured target \(target.summary)")
                    restoreFocus(to: target)
                }
            case .preservedClipboardPaste:
                if insertTextViaPreservedPaste(text) {
                    Log.debug("[INSERT] inserted via preserved clipboard paste")
                    return true
                }
            case .unicodeKeyboardFallback:
                if insertTextViaKeyboardEvents(text) {
                    Log.debug("[INSERT] inserted via Unicode keyboard events")
                    return true
                }
            }
        }

        Log.error("[INSERT] failed all insertion methods")
        return false
    }

    static func captureInsertionTarget() -> InsertionTarget? {
        guard AccessibilityChecker.isTrusted() else {
            Log.info("[INSERT] cannot capture target — no Accessibility")
            return nil
        }

        let sys = AXUIElementCreateSystemWide()
        var focusedValue: AnyObject?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
           let focusedValue {
            let element = focusedValue as! AXUIElement
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let target = makeInsertionTarget(processIdentifier: pid, element: element)
            Log.debug("[INSERT] captured target \(target.summary)")
            return target
        }

        if let app = NSWorkspace.shared.frontmostApplication {
            let target = InsertionTarget(
                processIdentifier: app.processIdentifier,
                appName: app.localizedName ?? "unknown",
                role: "unknown",
                subrole: "none",
                element: nil
            )
            Log.debug("[INSERT] captured app-only target \(target.summary)")
            return target
        }

        Log.debug("[INSERT] no focused target captured")
        return nil
    }

    private static func insertTextViaPreservedPaste(_ text: String) -> Bool {
        let snapshot = capturePasteboard()
        write(text)
        let changeCountAfterWrite = NSPasteboard.general.changeCount
        guard paste() else {
            restorePasteboardNow(snapshot)
            return false
        }
        restorePasteboard(snapshot, ifUnchangedSince: changeCountAfterWrite)
        return true
    }

    static func deleteBackward(count: Int) {
        guard count > 0 else { return }
        let src = CGEventSource(stateID: .hidSystemState)
        for _ in 0..<count {
            let down = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: true)
            let up = CGEvent(keyboardEventSource: src, virtualKey: 0x33, keyDown: false)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
            usleep(2_000)
        }
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
        let snapshot = capturePasteboard()
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
        restorePasteboardNow(snapshot)
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

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private static func makeInsertionTarget(
        processIdentifier: pid_t,
        element: AXUIElement?
    ) -> InsertionTarget {
        let app = NSRunningApplication(processIdentifier: processIdentifier)
        let role = element.flatMap { stringAttribute(kAXRoleAttribute as CFString, from: $0) } ?? "unknown"
        let subrole = element.flatMap { stringAttribute(kAXSubroleAttribute as CFString, from: $0) } ?? "none"
        return InsertionTarget(
            processIdentifier: processIdentifier,
            appName: app?.localizedName ?? "unknown",
            role: role,
            subrole: subrole,
            element: element
        )
    }

    private static func restoreFocus(to target: InsertionTarget) {
        guard target.processIdentifier > 0 else { return }

        if !target.isCurrentApp {
            let activate: () -> Void = {
                _ = NSRunningApplication(processIdentifier: target.processIdentifier)?
                    .activate(options: [.activateIgnoringOtherApps])
            }
            if Thread.isMainThread {
                activate()
            } else {
                DispatchQueue.main.sync { activate() }
            }
            usleep(80_000)
        }

        guard let element = target.element else { return }
        let appElement = AXUIElementCreateApplication(target.processIdentifier)
        _ = AXUIElementSetAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, element)
        _ = AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    private static func insertTextViaKeyboardEvents(_ text: String) -> Bool {
        guard AccessibilityChecker.isTrusted(), !text.isEmpty else { return false }
        let source = CGEventSource(stateID: .hidSystemState)

        for chunk in unicodeChunks(for: text, maxUnits: 32) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                return false
            }
            chunk.withUnsafeBufferPointer { buffer in
                down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            }
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(1_500)
        }
        return true
    }

    private static func unicodeChunks(for text: String, maxUnits: Int) -> [[UniChar]] {
        var chunks: [[UniChar]] = []
        var current: [UniChar] = []

        for character in text {
            let units = Array(String(character).utf16)
            if !current.isEmpty, current.count + units.count > maxUnits {
                chunks.append(current)
                current.removeAll(keepingCapacity: true)
            }
            current.append(contentsOf: units)
        }

        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func capturePasteboard() -> PasteboardSnapshot {
        let pasteboard = NSPasteboard.general
        let items: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var result: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    result[type] = data
                }
            }
            return result
        } ?? []
        return PasteboardSnapshot(items: items)
    }

    private static func restorePasteboard(_ snapshot: PasteboardSnapshot, ifUnchangedSince changeCount: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == changeCount else {
                Log.debug("[INSERT] skip clipboard restore; clipboard changed after paste")
                return
            }

            applyPasteboardSnapshot(snapshot)
        }
    }

    private static func restorePasteboardNow(_ snapshot: PasteboardSnapshot) {
        applyPasteboardSnapshot(snapshot)
    }

    private static func applyPasteboardSnapshot(_ snapshot: PasteboardSnapshot) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let items = snapshot.items.map { itemData in
            let item = NSPasteboardItem()
            for (type, data) in itemData {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
