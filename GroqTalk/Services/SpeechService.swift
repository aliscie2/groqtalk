import Foundation

enum SpeechService {

    static func speak(
        api: GroqAPIClient, player: AudioPlayer, voice: String,
        rate: Float, history: HistoryManager, usage: UsageTracker
    ) async {
        let start = CFAbsoluteTimeGetCurrent()
        player.reset()

        do {
            NotificationHelper.sendStatus("\u{1F50D} Getting selected text...")
            let text = ClipboardService.getSelectedText()
            try Task.checkCancellation()

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NotificationHelper.sendStatus("\u{274C} No text selected.")
                try? await Task.sleep(for: .seconds(2))
                NotificationHelper.clearStatus()
                return
            }

            let preview = String(text.prefix(60))

            if let cached = history.findCachedTTS(text: text) {
                Log.info("[TTS] cache hit (\(cached.count) bytes)")
                NotificationHelper.sendStatus("\u{1F50A} Speaking (cached)...", subtitle: preview)
                try Task.checkCancellation()
                await player.play(data: cached, rate: rate)
                NotificationHelper.sendStatus("\u{2705} Done", subtitle: preview)
                try? await Task.sleep(for: .seconds(2))
                NotificationHelper.clearStatus()
                return
            }

            NotificationHelper.sendStatus("\u{231B} Loading audio...", subtitle: preview)

            let speechText = TextCleaner.clean(text)
            let chunks = TextChunker.split(speechText)
            Log.info("[TTS] \(speechText.count) chars -> \(chunks.count) chunks")

            let allWav = try await streamChunks(
                chunks, api: api, player: player, voice: voice,
                rate: rate, usage: usage, preview: preview
            )

            if !allWav.isEmpty { history.saveTTSToHistory(text: text, ttsWavBytes: allWav) }

            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
            NotificationHelper.sendStatus("\u{2705} Done in \(elapsed)s", subtitle: preview)
            Log.info("[TTS] done in \(elapsed)s")
            try? await Task.sleep(for: .seconds(2))
            NotificationHelper.clearStatus()

        } catch is CancellationError {
            Log.info("[TTS] cancelled")
            NotificationHelper.sendStatus("\u{23F9} Stopped")
            try? await Task.sleep(for: .seconds(1))
            NotificationHelper.clearStatus()
        } catch {
            Log.error("[TTS] error: \(error)")
            NotificationHelper.sendStatus("\u{274C} Error: \(String(String(describing: error).prefix(80)))")
        }
    }

    private static func streamChunks(
        _ chunks: [String], api: GroqAPIClient, player: AudioPlayer,
        voice: String, rate: Float, usage: UsageTracker, preview: String
    ) async throws -> Data {
        guard !chunks.isEmpty else { return Data() }
        var allWav = Data()

        var nextFetch: Task<Data, Error>? = Task {
            try await api.speechData(text: chunks[0], voice: voice)
        }

        for i in 0..<chunks.count {
            try Task.checkCancellation()
            guard let fetchTask = nextFetch else { break }
            let wavData = try await fetchTask.value
            guard !wavData.isEmpty else { break }
            try Task.checkCancellation()

            if i + 1 < chunks.count {
                let next = chunks[i + 1]
                nextFetch = Task { try await api.speechData(text: next, voice: voice) }
            } else {
                nextFetch = nil
            }

            allWav.append(wavData)
            usage.logUsage(kind: "tts", chars: chunks[i].count)

            NotificationHelper.sendStatus(
                "\u{1F50A} Speaking \(i + 1)/\(chunks.count)...", subtitle: preview
            )
            await player.play(data: wavData, rate: rate)
            if player.cancelled { break }
        }

        return allWav
    }
}
