import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct TTSDialogTemplateTests {
    static func main() throws {
        let source = try String(
            contentsOfFile: "/Users/ali/Desktop/custom-tools/groqtalk/GroqTalk/UI/TTSDialog.swift",
            encoding: .utf8
        )

        expect(
            source.contains("if(isTokenRow(s,ARROW))return renderArrowRow(s);"),
            "Arrow rows should only render for compact structured token rows"
        )
        expect(
            !source.contains("if(s.indexOf(ARROW)>=0&&s.split(ARROW).length>=2)return renderArrowRow(s);"),
            "Prose sentences containing arrows must not be forced into kv-row layout"
        )
        expect(
            source.contains("if(isTokenRow(s,VBAR))return esc(s).replace(/\\\\u2502/g,"),
            "Pipe styling should also stay limited to compact token rows"
        )
        expect(
            !source.contains("replace(/^\\\\d{1,3}[\\\\.\\\\)]\\\\s+/,"),
            "Ordered-list markers should stay visible so the TTS dialog matches the original document"
        )
        expect(
            source.contains(".chunk.list-item .chunk-body{padding-left:1.25em;text-indent:-1.25em}"),
            "List chunks should keep original markers with a compact hanging indent"
        )
        expect(
            source.contains("if(/^[-*]\\\\s+/.test(trimmed))return '<span class=\"list-bullet\">"),
            "Unordered list chunks should render as real bullets instead of oversized cards"
        )
        expect(
            source.contains("function highlightWord(chunkIndex,wordIndex){"),
            "Dialog should expose a word highlight function for live speech tracking"
        )
        expect(
            source.contains("span.dataset.wordIndex=String(currentWord);"),
            "Clickable rendered words should carry stable word indices"
        )
        expect(
            source.contains(".word-jump.active-word{"),
            "Dialog should style the currently spoken word distinctly"
        )

        print("TTSDialog template tests passed")
    }
}
