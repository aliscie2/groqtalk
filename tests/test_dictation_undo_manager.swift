import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct DictationUndoManagerTests {
    static func main() {
        DictationUndoManager.recordPastedText("First sentence. Second sentence?")
        let first = DictationUndoManager.consumeDeleteInstruction()
        expect(first?.preview == "Second sentence?", "Expected last sentence preview")
        expect(first?.count == " Second sentence?".count, "Expected deletion count to include separator space")

        let second = DictationUndoManager.consumeDeleteInstruction()
        expect(second == nil, "Delete instruction should be consumed")

        DictationUndoManager.recordPastedText("Single sentence only")
        let third = DictationUndoManager.consumeDeleteInstruction()
        expect(third?.count == "Single sentence only".count, "Single sentence should delete entire paste")

        print("DictationUndoManager tests passed")
    }
}
