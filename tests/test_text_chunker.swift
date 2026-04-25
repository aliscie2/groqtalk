import Foundation

@main
struct TextChunkerTests {
    static func main() {
        testLongMarkdownLinkIsAtomic()
        testQwenProfileUsesFewerChunksForLongProse()
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

    private static func testQwenProfileUsesFewerChunksForLongProse() {
        let sentence = "This is a deliberately medium-length sentence that should be safe to merge with its neighbors for a smoother premium TTS voice."
        let input = Array(repeating: sentence, count: 4).joined(separator: " ")

        let kokoroChunks = TextChunker.split(input, profile: ConfigManager.ttsChunkProfile(for: .fast))
        let qwenChunks = TextChunker.split(input, profile: ConfigManager.ttsChunkProfile(for: .qwen))

        assert(!kokoroChunks.isEmpty, "Expected Kokoro chunking to produce chunks")
        assert(!qwenChunks.isEmpty, "Expected Qwen chunking to produce chunks")
        assert(qwenChunks.count < kokoroChunks.count, "Expected Qwen profile to reduce chunk count")
    }
}
