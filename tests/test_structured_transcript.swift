import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct StructuredTranscriptTests {
    static func main() {
        let json = """
        {"text":"Should we rebuild?","sentences":[{"text":" Should we rebuild?","start":0.0,"end":1.1,"tokens":[{"id":1,"text":" Should","start":0.0,"duration":0.2,"end":0.2},{"id":2,"text":" we","start":0.2,"duration":0.2,"end":0.4},{"id":3,"text":" re","start":0.4,"duration":0.2,"end":0.6},{"id":4,"text":"build","start":0.6,"duration":0.3,"end":0.9},{"id":5,"text":"?","start":0.9,"duration":0.2,"end":1.1}]}]}
        """

        let transcript = StructuredTranscriptBuilder.fromNDJSON(Data(json.utf8))
        expect(transcript.text == "Should we rebuild?", "Expected top-level text")
        expect(transcript.sentences.count == 1, "Expected one sentence")
        let sentence = transcript.sentences[0]
        expect(sentence.words.map(\.text) == ["Should", "we", "rebuild?"], "Expected token-to-word grouping")
        expect(sentence.words[2].start == 0.4, "Expected merged word to keep first token start")
        expect(sentence.words[2].end == 1.1, "Expected merged word to keep punctuation end")

        let gluedTimingJSON = """
        {"text":"Mesh is running Quan and Quan is doing the heavy judging.","sentences":[{"text":"Mesh is running Quan and Quan is doing the heavy judging.","start":0.0,"end":4.0,"tokens":[{"text":" Mesh","start":0.0,"end":0.2},{"text":" is","start":0.2,"end":0.4},{"text":" running","start":0.4,"end":0.7},{"text":"Quan","start":0.7,"end":1.0},{"text":" and","start":1.2,"end":1.4},{"text":"Quan","start":1.4,"end":1.8},{"text":" is","start":1.9,"end":2.1},{"text":" doing","start":2.1,"end":2.4},{"text":" the","start":2.4,"end":2.6},{"text":" heavy","start":2.6,"end":3.0},{"text":" judging.","start":3.0,"end":4.0}]}]}
        """
        let gluedTranscript = StructuredTranscriptBuilder.fromNDJSON(Data(gluedTimingJSON.utf8))
        expect(
            gluedTranscript.sentences[0].words.map(\.text) == [
                "Mesh", "is", "running", "Quan", "and", "Quan", "is", "doing", "the", "heavy", "judging."
            ],
            "Expected sentence text to remain authoritative when timing tokens are glued"
        )
        expect(gluedTranscript.sentences[0].words[2].start == 0.4, "Expected split word to keep segment start")
        expect(gluedTranscript.sentences[0].words[3].end == 1.0, "Expected split word to keep segment end")

        let apostropheJSON = """
        {"text":"It's not broken.","sentences":[{"text":"It's not broken.","start":0.0,"end":1.0,"tokens":[{"text":" It'","start":0.0,"end":0.2},{"text":"s","start":0.2,"end":0.3},{"text":" not","start":0.3,"end":0.6},{"text":" broken.","start":0.6,"end":1.0}]}]}
        """
        let apostropheTranscript = StructuredTranscriptBuilder.fromNDJSON(Data(apostropheJSON.utf8))
        expect(
            apostropheTranscript.sentences[0].words.map(\.text) == ["It's", "not", "broken."],
            "Expected split apostrophe tokens to align back to sentence text"
        )

        let whisperJSON = """
        {"text":" It is too slow.","segments":[{"id":0,"text":" It is too slow.","start":0.0,"end":1.2,"words":[{"word":" It","start":0.0,"end":0.2},{"word":" is","start":0.2,"end":0.4},{"word":" too","start":0.4,"end":0.7},{"word":" slow.","start":0.7,"end":1.2}]}]}
        """
        let whisperTranscript = StructuredTranscriptBuilder.fromNDJSON(Data(whisperJSON.utf8))
        expect(whisperTranscript.text == "It is too slow.", "Expected Whisper top-level text")
        expect(whisperTranscript.sentences.count == 1, "Expected one Whisper segment")
        expect(whisperTranscript.sentences[0].words.map(\.text) == ["It", "is", "too", "slow."], "Expected Whisper words to carry through")
        expect(whisperTranscript.sentences[0].start == 0.0, "Expected Whisper segment start")
        expect(whisperTranscript.sentences[0].end == 1.2, "Expected Whisper segment end")

        print("StructuredTranscript tests passed")
    }
}
