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
        expect(ConfigManager.defaultSTTMode == .parakeet, "Default STT mode should stay Parakeet for low latency")
        expect(ConfigManager.selectedSTTMode == .parakeet, "Missing selection should fall back to Parakeet")

        defaults.set("not-a-real-mode", forKey: key)
        expect(ConfigManager.selectedSTTMode == .parakeet, "Invalid selection should fall back to Parakeet")

        defaults.set(ConfigManager.STTMode.whisperLarge.rawValue, forKey: key)
        if !ConfigManager.isSTTModeSelectable(.whisperLarge) {
            expect(ConfigManager.selectedSTTMode == .parakeet, "Unavailable Whisper Large should fall back to Parakeet")
        }

        print("ConfigManager STT tests passed")
    }
}
