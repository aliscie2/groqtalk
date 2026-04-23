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
