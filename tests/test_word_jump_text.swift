import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct WordJumpTextTests {
    static func main() {
        expect(
            WordJumpText.suffix(from: "one two three", wordIndex: 0) == "one two three",
            "Expected word 0 to keep the whole string"
        )
        expect(
            WordJumpText.suffix(from: "one two three", wordIndex: 1) == "two three",
            "Expected word jumps to start from the requested word"
        )
        expect(
            WordJumpText.suffix(from: "one  two   three", wordIndex: 2) == "three",
            "Expected whitespace-preserving tokenization to ignore spacing-only pieces"
        )
        expect(
            WordJumpText.suffix(from: "one two three", wordIndex: 3) == nil,
            "Expected out-of-range word jumps to fail cleanly"
        )
        expect(
            WordJumpText.wordCount(in: "one  two   three") == 3,
            "Expected word counts to ignore repeated whitespace"
        )
        expect(
            WordJumpText.wordCount(in: "  ") == 0,
            "Expected whitespace-only input to have zero words"
        )

        let suffixChunks = WordJumpText.suffixChunks(
            from: ["alpha beta gamma", "delta epsilon", "zeta"],
            chunkIndex: 0,
            wordIndex: 1
        )
        expect(
            suffixChunks == ["beta gamma", "delta epsilon", "zeta"],
            "Expected chunk suffix generation to preserve remaining chunk boundaries"
        )

        expect(
            WordJumpText.suffixChunks(from: ["alpha"], chunkIndex: 1, wordIndex: 0) == nil,
            "Expected invalid chunk indices to fail cleanly"
        )

        print("WordJumpText tests passed")
    }
}
