import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct DialogCapabilitiesTests {
    static func main() {
        let payload = DialogCapabilities.buildPayload(
            chunks: [
                "Ali bought a MacBook at the Apple Store in San Francisco last Tuesday. He paid $2,499.",
                "Ali asked \"Do we deploy v1.2.3 at 3:30 PM?\"",
                "I'm SO ready."
            ],
            playbackRate: 1.25
        )

        expect(payload.chunks.count == 3, "Expected 3 payload chunks")

        let first = payload.chunks[0]
        expect(first.entities.contains(where: { $0.text == "Ali" && $0.kind == "person" }), "Missing Ali entity")
        expect(first.entities.contains(where: { $0.text == "Apple Store" && $0.kind == "organization" }), "Missing Apple Store entity")
        expect(first.entities.contains(where: { $0.text == "San Francisco" && $0.kind == "place" }), "Missing San Francisco entity")
        expect(first.firstMentions.contains("Ali"), "Ali should be a first mention in chunk 1")

        let second = payload.chunks[1]
        expect(second.isQuestion, "Chunk 2 should be marked as a question")
        expect(!second.firstMentions.contains("Ali"), "Ali should not be a first mention twice")
        expect(second.plain.contains("v1.2.3"), "Plain text should preserve version numbers")

        let third = payload.chunks[2]
        expect(third.words >= 3, "Word count should be populated")

        print("DialogCapabilities tests passed")
    }
}
