import Foundation

@main
struct TextChunkerTests {
    static func main() {
        testLongMarkdownLinkIsAtomic()
        print("TextChunker tests passed")
    }

    private static func testLongMarkdownLinkIsAtomic() {
        let label = Array(repeating: "reference", count: 35).joined(separator: " ")
        let link = "[\(label)](https://example.com/docs)"
        let input = "Intro. Please review \(link) because the markdown link must stay intact."

        let chunks = TextChunker.split(input)
        assert(
            chunks.contains { $0.contains(link) },
            "Expected long markdown link to remain in one chunk. Got: \(chunks)"
        )

        for chunk in chunks {
            let opens = chunk.filter { $0 == "[" }.count
            let closes = chunk.filter { $0 == "]" }.count
            assert(opens == closes, "Chunk has unbalanced markdown brackets: \(chunk)")
        }
    }
}
