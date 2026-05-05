import Foundation

enum Log {
    static func debug(_ message: String) {}
    static func info(_ message: String) {}
    static func error(_ message: String) {}
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct TextCleanerTests {
    static func main() {
        expect(
            TextCleaner.clean("Added a hook in [/Users/ali/Desktop/test/src/frontend/app/hooks/useDocumentContentSearch.ts]")
                == "Added a hook in [useDocumentContentSearch.ts]",
            "Expected absolute paths to speak only their final filename"
        )

        expect(
            TextCleaner.clean("See [useDocumentContentSearch.ts](/Users/ali/Desktop/test/src/frontend/app/hooks/useDocumentContentSearch.ts)")
                == "See useDocumentContentSearch.ts",
            "Expected Markdown file links to speak only the useful filename"
        )

        expect(
            TextCleaner.clean("Open /Users/ali/Desktop/custom-tools/groqtalk/GroqTalk/UI/TTSDialog.swift:531")
                == "Open TTSDialog.swift",
            "Expected line-numbered file paths to drop directories and line suffixes"
        )

        expect(
            TextCleaner.clean("Call /v1/chat/completions after setup.") == "Call /v1/chat/completions after setup.",
            "Expected API routes without filename extensions to remain intact"
        )

        print("TextCleaner tests passed")
    }
}
