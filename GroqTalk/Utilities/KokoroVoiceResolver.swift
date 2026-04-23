import Foundation

enum KokoroVoiceResolver {
    private static let fallbackRepoIDs = ["prince-canuma/Kokoro-82M"]

    static func runtimeVoiceSpecifier(
        voice: String,
        model: String,
        fallbackVoice: String? = nil
    ) -> String {
        guard isKokoroModel(model) else { return voice }
        if voice.hasSuffix(".safetensors") { return voice }

        if let resolved = localVoicePath(voice: voice, model: model) {
            return resolved
        }

        if let fallbackVoice,
           fallbackVoice != voice,
           let fallback = localVoicePath(voice: fallbackVoice, model: model) {
            return fallback
        }

        return voice
    }

    static func installedVoices(preferred voices: [String], model: String) -> [String] {
        guard isKokoroModel(model) else { return voices }
        let installed = voices.filter { localVoicePath(voice: $0, model: model) != nil }
        return installed.isEmpty ? voices : installed
    }

    static func localVoicePath(voice: String, model: String) -> String? {
        guard !voice.hasSuffix(".safetensors") else {
            return FileManager.default.fileExists(atPath: voice) ? voice : nil
        }

        for repoID in candidateRepoIDs(model: model) {
            guard let snapshotDir = snapshotDirectory(for: repoID) else { continue }
            let candidate = snapshotDir.appendingPathComponent("voices/\(voice).safetensors")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate.path
            }
        }
        return nil
    }

    private static func isKokoroModel(_ model: String) -> Bool {
        model.localizedCaseInsensitiveContains("kokoro")
    }

    private static func candidateRepoIDs(model: String) -> [String] {
        var ids: [String] = []
        if !model.isEmpty { ids.append(model) }
        if isKokoroModel(model) { ids.append(contentsOf: fallbackRepoIDs) }
        return unique(ids)
    }

    private static func snapshotDirectory(for repoID: String) -> URL? {
        let repoDir = cacheRoot().appendingPathComponent("models--" + repoID.replacingOccurrences(of: "/", with: "--"))
        let fm = FileManager.default
        let refsDir = repoDir.appendingPathComponent("refs")

        if let refNames = try? fm.contentsOfDirectory(atPath: refsDir.path) {
            for refName in refNames.sorted() {
                let refURL = refsDir.appendingPathComponent(refName)
                guard let snapshotID = try? String(contentsOf: refURL, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !snapshotID.isEmpty else { continue }
                let snapshotURL = repoDir.appendingPathComponent("snapshots/\(snapshotID)")
                if fm.fileExists(atPath: snapshotURL.path) { return snapshotURL }
            }
        }

        let snapshotsDir = repoDir.appendingPathComponent("snapshots")
        guard let snapshotURLs = try? fm.contentsOfDirectory(
            at: snapshotsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return snapshotURLs.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate > rhsDate
        }.first
    }

    private static func cacheRoot() -> URL {
        if let override = ProcessInfo.processInfo.environment["GROQTALK_HF_CACHE_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub", isDirectory: true)
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }
}
