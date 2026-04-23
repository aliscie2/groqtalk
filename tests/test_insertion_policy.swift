import Foundation

enum Log {
    static func info(_ msg: String) {}
    static func error(_ msg: String) {}
    static func debug(_ msg: String) {}
}

enum AccessibilityChecker {
    static func isTrusted() -> Bool { false }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct InsertionPolicyTests {
    static func main() {
        let targetedPlan = ClipboardService.insertionPlan(hasCapturedTarget: true)
        expect(
            targetedPlan == [
                .restoreCapturedFocus,
                .preservedClipboardPaste,
                .unicodeKeyboardFallback,
            ],
            "Captured-target insertion should restore focus, paste once, then only use keyboard if paste cannot be posted"
        )

        let untargetedPlan = ClipboardService.insertionPlan(hasCapturedTarget: false)
        expect(
            untargetedPlan == [
                .preservedClipboardPaste,
                .unicodeKeyboardFallback,
            ],
            "Untargeted insertion should paste once and avoid focus restore"
        )

        let primaryCommitCount = targetedPlan.filter { $0 == .preservedClipboardPaste }.count
        expect(primaryCommitCount == 1, "Insertion must have exactly one primary commit path")

        let source = try! String(
            contentsOfFile: "GroqTalk/Services/ClipboardService.swift",
            encoding: .utf8
        )
        expect(!source.contains("insertTextViaAX"), "AX insertion must not be reintroduced into dictation insertion")
        expect(!source.contains("AXUIElementSetAttributeValue(focused, kAXValueAttribute"),
               "AX value writes caused duplicate delayed commits and must stay out of insertion")

        print("InsertionPolicy tests passed")
    }
}
