import AppKit

@main
struct GroqTalkApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
