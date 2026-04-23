import Foundation

enum TTSWordAlignmentService {
    static func preferredAlignmentMode() -> ConfigManager.STTMode? {
        let selected = ConfigManager.selectedSTTMode
        if selected != .parakeet, ConfigManager.isSTTModeSelectable(selected) {
            return selected
        }
        if ConfigManager.isSTTModeSelectable(.whisperSmall) {
            return .whisperSmall
        }
        if ConfigManager.isSTTModeSelectable(.whisperLarge) {
            return .whisperLarge
        }
        return nil
    }

    static func alignChunk(
        spokenText: String,
        displayText: String,
        startWordIndex: Int,
        wavData: Data,
        api: GroqAPIClient,
        mode: ConfigManager.STTMode
    ) async -> [TimedDialogWord] {
        guard !spokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        for attempt in 1...2 {
            do {
                let transcript = try await transcriptForTiming(wavData: wavData, api: api, mode: mode)
                let transcriptWords = transcript.sentences.flatMap(\.words)
                guard !transcriptWords.isEmpty else {
                    Log.debug("[TTS ALIGN] \(mode.rawValue) returned no word timings")
                    return []
                }
                let aligned = TimedWordMatcher.buildAlignedWords(
                    transcriptWords: transcriptWords,
                    spokenText: spokenText,
                    displayText: displayText,
                    startWordIndex: startWordIndex
                )
                if aligned.isEmpty {
                    Log.debug("[TTS ALIGN] could not map transcript words onto dialog words")
                }
                return aligned
            } catch {
                if attempt == 2 {
                    Log.debug("[TTS ALIGN] \(mode.rawValue) failed: \(error.localizedDescription)")
                    return []
                }
                try? await Task.sleep(for: .milliseconds(450))
            }
        }

        return []
    }

    private static func transcriptForTiming(
        wavData: Data,
        api: GroqAPIClient,
        mode: ConfigManager.STTMode
    ) async throws -> StructuredTranscript {
        switch mode {
        case .parakeet:
            return try await api.transcribeMLXAudioDetails(
                wavData: wavData,
                model: ConfigManager.parakeetModel,
                verbose: true
            )
        case .whisperSmall, .whisperLarge:
            return try await api.transcribeWhisperServerDetails(
                wavData: wavData,
                baseURL: ConfigManager.sttServerURL(for: mode),
                verbose: true
            )
        }
    }
}
