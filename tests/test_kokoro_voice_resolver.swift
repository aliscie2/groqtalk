import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError(message) }
}

func makeVoiceFile(root: URL, repoID: String, snapshot: String, voice: String) {
    let repoDir = root.appendingPathComponent("models--" + repoID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    let refsDir = repoDir.appendingPathComponent("refs", isDirectory: true)
    let voicesDir = repoDir.appendingPathComponent("snapshots/\(snapshot)/voices", isDirectory: true)
    try! FileManager.default.createDirectory(at: refsDir, withIntermediateDirectories: true)
    try! FileManager.default.createDirectory(at: voicesDir, withIntermediateDirectories: true)
    try! snapshot.write(to: refsDir.appendingPathComponent("main"), atomically: true, encoding: .utf8)
    FileManager.default.createFile(atPath: voicesDir.appendingPathComponent("\(voice).safetensors").path, contents: Data("ok".utf8))
}

@main
struct KokoroVoiceResolverTests {
    static func main() {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("groqtalk-kokoro-\(UUID().uuidString)", isDirectory: true)
        try! fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        setenv("GROQTALK_HF_CACHE_ROOT", root.path, 1)

        makeVoiceFile(root: root, repoID: "mlx-community/Kokoro-82M-bf16", snapshot: "bf16-snap", voice: "am_adam")
        makeVoiceFile(root: root, repoID: "prince-canuma/Kokoro-82M", snapshot: "base-snap", voice: "af_heart")

        let resolved = KokoroVoiceResolver.runtimeVoiceSpecifier(
            voice: "am_adam",
            model: "mlx-community/Kokoro-82M-bf16"
        )
        expect(resolved.hasSuffix("/models--mlx-community--Kokoro-82M-bf16/snapshots/bf16-snap/voices/am_adam.safetensors"),
               "Expected runtime voice to resolve through the selected model cache")

        let installed = KokoroVoiceResolver.installedVoices(
            preferred: ["af_heart", "am_adam", "am_echo"],
            model: "mlx-community/Kokoro-82M-bf16"
        )
        expect(installed == ["af_heart", "am_adam"],
               "Expected installed voices to include model and fallback-repo matches")

        let fallback = KokoroVoiceResolver.runtimeVoiceSpecifier(
            voice: "am_echo",
            model: "mlx-community/Kokoro-82M-bf16",
            fallbackVoice: "af_heart"
        )
        expect(fallback.hasSuffix("/models--prince-canuma--Kokoro-82M/snapshots/base-snap/voices/af_heart.safetensors"),
               "Expected unresolved voices to fall back to a known-good local voice")

        print("KokoroVoiceResolver tests passed")
    }
}
