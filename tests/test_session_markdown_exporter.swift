import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct SessionMarkdownExporterTests {
    static func main() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"

        let start = formatter.date(from: "20260422_090000")!
        let entries = [
            HistoryEntry(
                timestamp: "20260422_090500",
                wavPath: "/tmp/rec_1.wav",
                ttsWavPath: nil,
                transcript: "uh hello hello world",
                cleaned: "hello world",
                pending: nil
            ),
            HistoryEntry(
                timestamp: "20260422_091000",
                wavPath: nil,
                ttsWavPath: "/tmp/tts_1.wav",
                transcript: nil,
                cleaned: "## Notes\\nAli met Sarah.",
                pending: nil
            ),
        ]

        let markdown = SessionMarkdownExporter.render(
            entries: entries,
            since: start,
            generatedAt: start.addingTimeInterval(600),
            activeDialogText: "Pending dialog text"
        )

        expect(markdown.contains("# GroqTalk Session"), "Missing document title")
        expect(markdown.contains("## Dictations"), "Missing dictations section")
        expect(markdown.contains("hello world"), "Missing cleaned dictation")
        expect(markdown.contains("uh hello hello world"), "Missing raw dictation")
        expect(markdown.contains("## Read Aloud"), "Missing TTS section")
        expect(markdown.contains("Ali met Sarah."), "Missing spoken text")
        expect(markdown.contains("Pending dialog text"), "Missing active dialog text")

        print("SessionMarkdownExporter tests passed")
    }
}
