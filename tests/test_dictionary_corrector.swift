import Foundation

struct ConfigManager {
    struct DictionaryEntry {
        let canonical: String
        let aliases: [String]
    }

    static func dictionaryEntries() -> [DictionaryEntry] { [] }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct DictionaryCorrectorTests {
    static func main() {
        let entries = [
            ConfigManager.DictionaryEntry(canonical: "qwen", aliases: ["quan"]),
            ConfigManager.DictionaryEntry(canonical: "Tauri", aliases: ["tori"]),
            ConfigManager.DictionaryEntry(canonical: "TypeScript", aliases: ["type script", "typescript"]),
        ]

        expect(
            DictionaryCorrector.apply(to: "Quan is faster than before.", entries: entries) == "qwen is faster than before.",
            "Expected explicit alias to map Quan to qwen"
        )
        expect(
            DictionaryCorrector.apply(to: "tori app", entries: entries) == "Tauri app",
            "Expected explicit alias to map tori to Tauri"
        )
        expect(
            DictionaryCorrector.apply(to: "I prefer type script here.", entries: entries) == "I prefer TypeScript here.",
            "Expected explicit phrase alias to map to canonical form"
        )
        expect(
            DictionaryCorrector.apply(to: "Test quantity and with mine.", entries: [
                ConfigManager.DictionaryEntry(canonical: "qwen", aliases: ["quantity"]),
                ConfigManager.DictionaryEntry(canonical: "tauri", aliases: []),
                ConfigManager.DictionaryEntry(canonical: "weavmind", aliases: ["with mine"]),
            ]) == "Test qwen and weavmind.",
            "Expected explicit aliases to correct quantity and with mine"
        )
        expect(
            DictionaryCorrector.apply(to: "The team shipped quality features quickly.", entries: [
                ConfigManager.DictionaryEntry(canonical: "qwen", aliases: ["quan"]),
                ConfigManager.DictionaryEntry(canonical: "tauri", aliases: ["tori"]),
            ]) == "The team shipped quality features quickly.",
            "Expected unrelated words to remain unchanged"
        )
        expect(
            DictionaryCorrector.apply(to: "I said two words.", entries: [
                ConfigManager.DictionaryEntry(canonical: "tauri", aliases: ["tori", "ta uri"]),
            ]) == "I said two words.",
            "Expected dictionary to skip unrelated words like two"
        )
        expect(
            DictionaryCorrector.apply(to: "ta uri app", entries: [
                ConfigManager.DictionaryEntry(canonical: "tauri", aliases: ["tori", "ta uri"]),
            ]) == "tauri app",
            "Expected explicit phrase alias to map ta uri to tauri"
        )

        print("DictionaryCorrector tests passed")
    }
}
