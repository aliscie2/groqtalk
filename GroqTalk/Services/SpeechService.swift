import Foundation

enum SpeechService {

    struct LastSession {
        let text: String
        let prettified: String
        let chunks: [String]
    }
    static var lastSession: LastSession?
    static var chunkAudio: [Int: Data] = [:]
    private static var fetchTasks: [Int: Task<Data, Error>] = [:]
    // WordAligner tasks per chunk; populated only when dialog is visible.
    private static var alignTasks: [Int: Task<Void, Never>] = [:]
    private static let maxConcurrent = 3

    // MARK: - Public entry points

    static func speak(
        api: GroqAPIClient, player: AudioPlayer, voice: String, model: String,
        rate: Float, history: HistoryManager, usage: UsageTracker
    ) async {
        let start = CFAbsoluteTimeGetCurrent()
        player.reset()
        do {
            NotificationHelper.sendStatus("\u{1F50D} Getting selected text...")
            var text = ClipboardService.getSelectedText()
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                text = ClipboardService.read()
                if !text.isEmpty { Log.info("[TTS] no selection — using clipboard (\(text.count) chars)") }
            }
            try Task.checkCancellation()

            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                NotificationHelper.sendStatus("\u{274C} No text selected or copied.")
                try? await Task.sleep(for: .seconds(2)); NotificationHelper.clearStatus()
                return
            }

            let (preview, speechChunks, showDialog) = prepareSession(text: text)

            if let cached = history.findCachedTTS(text: text) {
                Log.info("[TTS] cache hit (\(cached.count) bytes)")
                NotificationHelper.sendStatus("\u{1F50A} Speaking (cached)...", subtitle: preview)
                try Task.checkCancellation()
                if showDialog {
                    for i in 0..<speechChunks.count { TTSDialog.shared.enableChunk(i) }
                    TTSDialog.shared.setActiveChunk(0)
                }
                await player.play(data: cached, rate: rate)
                NotificationHelper.sendStatus("\u{2705} Done", subtitle: preview)
                if showDialog { TTSDialog.shared.finish() }
                try? await Task.sleep(for: .seconds(2)); NotificationHelper.clearStatus()
                return
            }

            NotificationHelper.sendStatus("\u{231B} Loading audio...", subtitle: preview)
            launchParallelFetches(chunks: speechChunks, api: api, voice: voice, model: model, showDialog: showDialog)
            let allWav = try await playFromCache(
                startAt: 0, player: player, rate: rate, usage: usage, preview: preview, showDialog: showDialog
            )
            try Task.checkCancellation()
            if !allWav.isEmpty { history.saveTTSToHistory(text: text, ttsWavBytes: allWav) }

            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
            NotificationHelper.sendStatus("\u{2705} Done in \(elapsed)s", subtitle: preview)
            Log.info("[TTS] done in \(elapsed)s")
            if showDialog { TTSDialog.shared.finish() }
            try? await Task.sleep(for: .seconds(2)); NotificationHelper.clearStatus()

        } catch is CancellationError {
            Log.info("[TTS] cancelled")
            NotificationHelper.sendStatus("\u{23F9} Stopped")
            try? await Task.sleep(for: .seconds(1)); NotificationHelper.clearStatus()
        } catch {
            handleError(error, tag: "TTS", notify: true)
        }
    }

    static func speakDirect(
        text: String,
        api: GroqAPIClient, player: AudioPlayer, voice: String, model: String,
        rate: Float, history: HistoryManager, usage: UsageTracker
    ) async {
        player.reset()
        do {
            let (preview, speechChunks, showDialog) = prepareSession(text: text)
            Log.info("[TTS] speakDirect \(text.count) chars -> \(speechChunks.count) chunks")
            launchParallelFetches(chunks: speechChunks, api: api, voice: voice, model: model, showDialog: showDialog)
            let allWav = try await playFromCache(
                startAt: 0, player: player, rate: rate, usage: usage, preview: preview, showDialog: showDialog
            )
            try Task.checkCancellation()
            if !allWav.isEmpty { history.saveTTSToHistory(text: text, ttsWavBytes: allWav) }
            if showDialog { TTSDialog.shared.finish() }
        } catch is CancellationError {
            Log.info("[TTS] speakDirect cancelled")
        } catch {
            handleError(error, tag: "TTS speakDirect", notify: false)
        }
    }

    static func resumeFromChunk(
        startAt: Int,
        api: GroqAPIClient, player: AudioPlayer, voice: String, model: String,
        rate: Float, usage: UsageTracker,
        startTime: TimeInterval = 0
    ) async {
        guard let session = lastSession else { Log.error("[TTS] resumeFromChunk: no session"); return }
        guard startAt >= 0, startAt < session.chunks.count else { return }
        Log.info("[TTS] resumeFromChunk \(startAt) of \(session.chunks.count) startTime=\(startTime)")
        player.reset()

        if fetchTasks.isEmpty {
            launchParallelFetches(chunks: session.chunks, api: api, voice: voice, model: model, showDialog: true)
        }

        do {
            _ = try await playFromCache(
                startAt: startAt, player: player, rate: rate, usage: usage,
                preview: String(session.text.prefix(60)), showDialog: true, startTime: startTime
            )
            try Task.checkCancellation()
            if ConfigManager.showTTSDialog { TTSDialog.shared.finish() }
        } catch is CancellationError {
            Log.info("[TTS] resume cancelled")
        } catch {
            handleError(error, tag: "TTS resume", notify: false)
        }
    }

    // MARK: - Session helpers

    private static func prepareSession(text: String) -> (preview: String, speechChunks: [String], showDialog: Bool) {
        let rawChunks = TextChunker.split(text)
        let speechChunks = rawChunks.map { TextCleaner.clean($0) }
        Log.info("[TTS] \(text.count) chars -> \(rawChunks.count) chunks")
        let showDialog = ConfigManager.showTTSDialog
        if showDialog { TTSDialog.shared.show(text: text, chunks: rawChunks) }
        lastSession = LastSession(text: text, prettified: text, chunks: speechChunks)
        return (String(text.prefix(60)), speechChunks, showDialog)
    }

    private static func handleError(_ error: Error, tag: String, notify: Bool) {
        Log.error("[\(tag)] error: \(error)")
        let short = humanError(error)
        if notify { NotificationHelper.sendStatus("\u{274C} \(short)") }
        if ConfigManager.showTTSDialog { TTSDialog.shared.error(short) }
    }

    // MARK: - Parallel fetch

    private static func launchParallelFetches(
        chunks: [String], api: GroqAPIClient, voice: String, model: String, showDialog: Bool
    ) {
        chunkAudio.removeAll()
        fetchTasks.removeAll()
        alignTasks.values.forEach { $0.cancel() }
        alignTasks.removeAll()
        Log.info("[TTS] launching \(chunks.count) fetches (max \(maxConcurrent) concurrent)")

        var cursor = 0
        func launchNext() {
            guard cursor < chunks.count else { return }
            let i = cursor; let chunk = chunks[cursor]; cursor += 1
            fetchTasks[i] = Task {
                var lastError: Error?
                for attempt in 1...2 {
                    do {
                        let data = try await api.speechData(text: chunk, voice: voice, model: model)
                        chunkAudio[i] = data
                        if showDialog {
                            let duration = wavDuration(data)
                            await MainActor.run {
                                TTSDialog.shared.enableChunk(i)
                                TTSDialog.shared.setChunkDuration(i, duration: duration)
                            }
                            launchAlignment(chunkIdx: i, wavData: data)
                        }
                        Log.debug("[TTS] chunk \(i) fetched (\(data.count) bytes)")
                        launchNext()
                        return data
                    } catch {
                        lastError = error
                        if attempt < 2 {
                            Log.info("[TTS] chunk \(i) retry after: \(error.localizedDescription)")
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                    }
                }
                launchNext()
                throw lastError ?? NSError(domain: "TTS", code: -1)
            }
        }
        for _ in 0..<min(maxConcurrent, chunks.count) { launchNext() }
    }

    private static func launchAlignment(chunkIdx: Int, wavData: Data) {
        alignTasks[chunkIdx]?.cancel()
        alignTasks[chunkIdx] = Task.detached(priority: .utility) {
            do {
                let words = try await WordAligner.align(wavData: wavData)
                if Task.isCancelled { return }
                Log.debug("[ALIGN] chunk \(chunkIdx) -> \(words.count) words")
                await MainActor.run { TTSDialog.shared.setChunkWords(chunkIdx, words: words) }
            } catch is CancellationError {
                // normal
            } catch {
                Log.info("[ALIGN] chunk \(chunkIdx) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Play from cache

    private static func playFromCache(
        startAt: Int, player: AudioPlayer, rate: Float,
        usage: UsageTracker, preview: String, showDialog: Bool,
        startTime: TimeInterval = 0
    ) async throws -> Data {
        guard let session = lastSession else { return Data() }
        let chunks = session.chunks
        guard startAt < chunks.count else { return Data() }
        var allWav = Data()

        for i in startAt..<chunks.count {
            try Task.checkCancellation()
            let wavData: Data
            if let cached = chunkAudio[i] { wavData = cached }
            else if let task = fetchTasks[i] { wavData = try await task.value }
            else { Log.error("[TTS] no fetch task for chunk \(i)"); break }
            guard !wavData.isEmpty else { break }
            try Task.checkCancellation()

            allWav.append(wavData)
            usage.logUsage(kind: "tts", chars: chunks[i].count)
            NotificationHelper.sendStatus("\u{1F50A} Speaking \(i + 1)/\(chunks.count)...", subtitle: preview)
            if showDialog { TTSDialog.shared.setActiveChunk(i) }

            // 15 Hz playhead poller for karaoke highlight; only while dialog visible.
            let pollerTask: Task<Void, Never>? = showDialog ? Task { [i, player] in
                while !Task.isCancelled {
                    TTSDialog.shared.setChunkPlayhead(i, time: player.currentTime)
                    try? await Task.sleep(for: .milliseconds(66))
                }
            } : nil

            // startTime applies only to first chunk (mid-chunk seek from word click).
            let offset: TimeInterval = (i == startAt) ? startTime : 0
            await player.play(data: wavData, rate: rate, startAt: offset)
            pollerTask?.cancel()
            if player.cancelled { break }
        }
        return allWav
    }

    // MARK: - WAV duration / errors

    /// Parse WAV header for duration in seconds. Returns 0 on malformed input.
    private static func wavDuration(_ data: Data) -> TimeInterval {
        guard data.count >= 44,
              data[0] == 0x52, data[1] == 0x49, data[2] == 0x46, data[3] == 0x46,
              data[8] == 0x57, data[9] == 0x41, data[10] == 0x56, data[11] == 0x45
        else { return 0 }

        func u32LE(at off: Int) -> UInt32 {
            UInt32(data[off]) | (UInt32(data[off+1]) << 8)
                | (UInt32(data[off+2]) << 16) | (UInt32(data[off+3]) << 24)
        }
        var byteRate: UInt32 = 0, dataSize: UInt32 = 0, off = 12
        while off + 8 <= data.count {
            let id0 = data[off], id1 = data[off+1], id2 = data[off+2], id3 = data[off+3]
            let size = u32LE(at: off + 4)
            if id0 == 0x66, id1 == 0x6D, id2 == 0x74, id3 == 0x20, off + 24 <= data.count {
                byteRate = u32LE(at: off + 16)
            } else if id0 == 0x64, id1 == 0x61, id2 == 0x74, id3 == 0x61 {
                dataSize = size; break
            }
            off += 8 + Int(size)
        }
        guard byteRate > 0, dataSize > 0 else { return 0 }
        return TimeInterval(dataSize) / TimeInterval(byteRate)
    }

    private static func humanError(_ err: Error) -> String {
        let ns = err as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case -1004: return "TTS server not running (port 8723)"
            case -1001: return "TTS request timed out"
            case -1017: return "TTS server returned bad response"
            case -999:  return "Cancelled"
            default:    return "Network error \(ns.code)"
            }
        }
        return String(String(describing: err).prefix(80))
    }
}
