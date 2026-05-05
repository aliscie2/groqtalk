import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

@main
struct ConfigManagerSTTTests {
    static func main() {
        let key = "selectedSTTMode"
        let defaults = UserDefaults.standard
        let oldValue = defaults.string(forKey: key)
        defer {
            if let oldValue {
                defaults.set(oldValue, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        let expectedDefault: ConfigManager.STTMode = ConfigManager.isSTTModeSelectable(.whisperLarge)
            ? .whisperLarge
            : .parakeet
        expect(ConfigManager.defaultSTTMode == expectedDefault, "Default STT mode should prefer Whisper Large when available")
        expect(ConfigManager.selectedSTTMode == expectedDefault, "Missing selection should fall back to the preferred available STT mode")

        defaults.set("not-a-real-mode", forKey: key)
        expect(ConfigManager.selectedSTTMode == expectedDefault, "Invalid selection should fall back to the preferred available STT mode")

        defaults.set(ConfigManager.STTMode.whisperLarge.rawValue, forKey: key)
        if !ConfigManager.isSTTModeSelectable(.whisperLarge) {
            expect(ConfigManager.selectedSTTMode == expectedDefault, "Unavailable Whisper Large should fall back to the preferred available STT mode")
        }

        let prompt = ConfigManager.sttInitialPrompt()
        expect(prompt.contains("mesh LLM"), "STT prompt should bias acronym-heavy project terms")
        expect(prompt.contains("Petra Cursor"), "STT prompt should include multi-word software terms")
        expect(prompt.contains("Tauri app"), "STT prompt should bias app phrasing")

        print("ConfigManager STT tests passed")
    }
}
