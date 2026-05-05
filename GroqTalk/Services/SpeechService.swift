import Foundation

enum SpeechService {
    private actor FetchGate {
        private let limit: Int
        private var inFlight = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []

        init(limit: Int) {
            self.limit = limit
        }

        func acquire() async {
            if inFlight < limit {
                inFlight += 1
                return
            }
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func release() {
            if let waiter = waiters.first {
                waiters.removeFirst()
                waiter.resume()
            } else {
                inFlight = max(0, inFlight - 1)
            }
        }
    }

    struct LastSession {
        let text: String
        let rawChunks: [String]
        let chunks: [String]
        let displayChunks: [String]
    }
    private struct ChunkHighlightPlan {
        let dialogIndex: Int
        let startWordIndex: Int
        let playableWordCount: Int
    }
    private struct PlaybackContext {
        let dialogIndex: Int
        let wordTracker: LiveWordTracker?
    }

    static var lastSession: LastSession?
    private static var fetchTasks: [Int: Task<Data, Error>] = [:]
    private static let playbackContextLock = NSLock()
    private static var playbackContext: PlaybackContext?
    private static let audioCacheLock = NSLock()
    private static var cachedWAVByDialogIndex: [Int: Data] = [:]
    private static var cachedTimedWordsByDialogIndex: [Int: [TimedDialogWord]] = [:]

    // MARK: - Public entry points

    static func cancelOutstandingFetches(reason: String) {
        guard !fetchTasks.isEmpty else { return }
        Log.info("[TTS] cancelling \(fetchTasks.count) outstanding fetches — \(reason)")
        cancelFetchTasks()
        fetchTasks.removeAll()
    }

    static func seekToWordIfCurrentlyPlaying(
        dialogIndex: Int,
        wordIndex: Int,
        player: AudioPlayer
    ) -> Bool {
        playbackContextLock.lock()
        let context = playbackContext
        playbackContextLock.unlock()

        guard context?.dialogIndex == dialogIndex,
              let wordTracker = context?.wordTracker,
              player.duration > 0,
              let targetTime = wordTracker.playbackTime(forWordIndex: wordIndex, duration: player.duration) else {
            return false
        }

        let seekTime = max(0, targetTime - 0.035)
        guard player.seek(to: seekTime) else { return false }
        TTSDialog.shared.setActiveChunk(dialogIndex)
        TTSDialog.shared.setActiveWord(dialogIndex: dialogIndex, wordIndex: wordIndex)
        Log.info("[TTS] seeked active chunk \(dialogIndex) to word \(wordIndex) @ \(String(format: "%.2f", seekTime))s")
        return true
    }

    static func hasCachedAudio(dialogIndex: Int) -> Bool {
        cachedWAV(dialogIndex: dialogIndex) != nil
    }

    static func speak(
        api: GroqAPIClient, player: AudioPlayer, voice: String, model: String,
        rate: Float, history: HistoryManager, usage: UsageTracker
    ) async {
        let start = CFAbsoluteTimeGetCurrent()
        player.reset()
        defer { cancelOutstandingFetches(reason: "speak finished") }
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

            let (preview, speechChunks, showDialog) = prepareSession(text: text, rate: rate, model: model)
            let cacheKey = HistoryManager.ttsCacheKey(model: model, voice: voice)

            if let cached = history.findCachedTTS(text: text, cacheKey: cacheKey) {
                Log.info("[TTS] cache hit (\(cached.count) bytes)")
                NotificationHelper.sendStatus("\u{1F50A} Speaking (cached)...", subtitle: preview)
                try Task.checkCancellation()
                if showDialog {
                    await MainActor.run {
                        for i in 0..<speechChunks.count { TTSDialog.shared.enableChunk(i) }
                        TTSDialog.shared.setActiveChunk(0)
                    }
                }
                await player.play(data: cached, rate: rate)
                NotificationHelper.sendStatus("\u{2705} Done", subtitle: preview)
                if showDialog { await MainActor.run { TTSDialog.shared.finish() } }
                try? await Task.sleep(for: .seconds(2)); NotificationHelper.clearStatus()
                return
            }

            NotificationHelper.sendStatus("\u{231B} Loading audio...", subtitle: preview)
            launchParallelFetches(chunks: speechChunks, api: api, voice: voice, model: model, showDialog: showDialog)
            let allWav = try await playFromCache(
                startAt: 0, api: api, player: player, rate: rate, usage: usage, preview: preview, showDialog: showDialog
            )
            try Task.checkCancellation()
            if !allWav.isEmpty { history.saveTTSToHistory(text: text, ttsWavBytes: allWav, cacheKey: cacheKey) }

            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
            NotificationHelper.sendStatus("\u{2705} Done in \(elapsed)s", subtitle: preview)
            Log.info("[TTS] done in \(elapsed)s")
            if showDialog { await MainActor.run { TTSDialog.shared.finish() } }
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
        defer { cancelOutstandingFetches(reason: "direct speak finished") }
        do {
            let (preview, speechChunks, showDialog) = prepareSession(text: text, rate: rate, model: model)
            let cacheKey = HistoryManager.ttsCacheKey(model: model, voice: voice)
            Log.info("[TTS] speakDirect \(text.count) chars -> \(speechChunks.count) chunks")
            launchParallelFetches(chunks: speechChunks, api: api, voice: voice, model: model, showDialog: showDialog)
            let allWav = try await playFromCache(
                startAt: 0, api: api, player: player, rate: rate, usage: usage, preview: preview, showDialog: showDialog
            )
            try Task.checkCancellation()
            if !allWav.isEmpty { history.saveTTSToHistory(text: text, ttsWavBytes: allWav, cacheKey: cacheKey) }
            if showDialog { await MainActor.run { TTSDialog.shared.finish() } }
        } catch is CancellationError {
            Log.info("[TTS] speakDirect cancelled")
        } catch {
            if isBenignCancellation(error) {
                Log.info("[TTS] speakDirect cancelled")
            } else {
                handleError(error, tag: "TTS speakDirect", notify: false)
            }
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
        defer { cancelOutstandingFetches(reason: "chunk resume finished") }

        let speechChunks = Array(session.chunks.dropFirst(startAt))
        let dialogIndices = Array(startAt..<session.chunks.count)
        launchParallelFetches(
            chunks: speechChunks,
            api: api,
            voice: voice,
            model: model,
            showDialog: true,
            dialogIndices: dialogIndices
        )

        do {
            _ = try await playFromCache(
                startAt: 0, api: api, player: player, rate: rate, usage: usage,
                preview: String(session.text.prefix(60)), showDialog: true, startTime: startTime,
                chunksOverride: speechChunks,
                highlightIndices: dialogIndices
            )
            try Task.checkCancellation()
            if ConfigManager.showTTSDialog { await MainActor.run { TTSDialog.shared.finish() } }
        } catch is CancellationError {
            Log.info("[TTS] resume cancelled")
        } catch {
            if isBenignCancellation(error) {
                Log.info("[TTS] resume cancelled")
            } else {
                handleError(error, tag: "TTS resume", notify: false)
            }
        }
    }

    static func resumeFromWord(
        chunkIndex: Int,
        wordIndex: Int,
        api: GroqAPIClient,
        player: AudioPlayer,
        voice: String,
        model: String,
        rate: Float,
        usage: UsageTracker,
        firstChunkSuffixOverride: String? = nil
    ) async {
        guard let session = lastSession else {
            Log.error("[TTS] resumeFromWord: no session")
            return
        }
        defer { cancelOutstandingFetches(reason: "word resume finished") }

        if let cachedFullChunk = cachedWAV(dialogIndex: chunkIndex),
           session.chunks.indices.contains(chunkIndex) {
            let speechChunks = Array(session.chunks.dropFirst(chunkIndex))
            let dialogIndices = Array(chunkIndex..<session.chunks.count)
            guard !speechChunks.isEmpty else { return }

            let startTime = cachedWordStartTime(
                dialogIndex: chunkIndex,
                wordIndex: wordIndex,
                wavData: cachedFullChunk
            )
            Log.info(
                "[TTS] resumeFromWord cached chunk=\(chunkIndex) word=\(wordIndex) startTime=\(String(format: "%.2f", startTime)) -> \(speechChunks.count) chunks"
            )

            player.reset()
            launchParallelFetches(
                chunks: speechChunks,
                api: api,
                voice: voice,
                model: model,
                showDialog: ConfigManager.showTTSDialog,
                dialogIndices: dialogIndices
            )

            do {
                _ = try await playFromCache(
                    startAt: 0,
                    api: api,
                    player: player,
                    rate: rate,
                    usage: usage,
                    preview: String(speechChunks[0].prefix(60)),
                    showDialog: ConfigManager.showTTSDialog,
                    startTime: startTime,
                    chunksOverride: speechChunks,
                    highlightIndices: dialogIndices,
                    wordStartOffsets: [wordIndex] + Array(repeating: 0, count: max(0, speechChunks.count - 1))
                )
                try Task.checkCancellation()
                if ConfigManager.showTTSDialog { await MainActor.run { TTSDialog.shared.finish() } }
            } catch is CancellationError {
                Log.info("[TTS] resumeFromWord cached cancelled")
            } catch {
                if isBenignCancellation(error) {
                    Log.info("[TTS] resumeFromWord cached cancelled")
                } else {
                    handleError(error, tag: "TTS resumeFromWord cached", notify: false)
                }
            }
            return
        }

        let override = firstChunkSuffixOverride?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffixChunks: [String]?
        if let override, !override.isEmpty, session.displayChunks.indices.contains(chunkIndex) {
            suffixChunks = [override] + Array(session.displayChunks.dropFirst(chunkIndex + 1))
        } else {
            suffixChunks = WordJumpText.suffixChunks(
                from: session.displayChunks,
                chunkIndex: chunkIndex,
                wordIndex: wordIndex
            )
        }
        guard let suffixChunks else {
            Log.error("[TTS] resumeFromWord: invalid chunk/word \(chunkIndex)/\(wordIndex)")
            return
        }

        let indexedSpeechChunks = suffixChunks.enumerated().compactMap { offset, chunk -> (Int, String)? in
            let cleaned = TextCleaner.clean(chunk)
            guard !cleaned.isEmpty else { return nil }
            return (chunkIndex + offset, cleaned)
        }
        guard !indexedSpeechChunks.isEmpty else {
            Log.error("[TTS] resumeFromWord: suffix produced no speech chunks")
            return
        }

        Log.info("[TTS] resumeFromWord chunk=\(chunkIndex) word=\(wordIndex) -> \(indexedSpeechChunks.count) chunks")
        player.reset()

        let speechChunks = indexedSpeechChunks.map(\.1)
        let dialogIndices = indexedSpeechChunks.map(\.0)

        launchParallelFetches(
            chunks: speechChunks,
            api: api,
            voice: voice,
            model: model,
            showDialog: ConfigManager.showTTSDialog,
            dialogIndices: dialogIndices
        )

        do {
            _ = try await playFromCache(
                startAt: 0,
                api: api,
                player: player,
                rate: rate,
                usage: usage,
                preview: String(speechChunks[0].prefix(60)),
                showDialog: ConfigManager.showTTSDialog,
                chunksOverride: speechChunks,
                highlightIndices: dialogIndices,
                wordStartOffsets: [wordIndex] + Array(repeating: 0, count: max(0, speechChunks.count - 1))
            )
            try Task.checkCancellation()
            if ConfigManager.showTTSDialog { await MainActor.run { TTSDialog.shared.finish() } }
        } catch is CancellationError {
            Log.info("[TTS] resumeFromWord cancelled")
        } catch {
            if isBenignCancellation(error) {
                Log.info("[TTS] resumeFromWord cancelled")
            } else {
                handleError(error, tag: "TTS resumeFromWord", notify: false)
            }
        }
    }

    // MARK: - Session helpers

    private static func prepareSession(
        text: String,
        rate: Float,
        model: String
    ) -> (preview: String, speechChunks: [String], showDialog: Bool) {
        let engine = ConfigManager.ttsEngine(for: model) ?? ConfigManager.selectedTTSEngine
        let chunkProfile = ConfigManager.ttsChunkProfile(for: engine)
        let rawChunks = TextChunker.split(text, profile: chunkProfile)
        let speechChunks = rawChunks.map { TextCleaner.clean($0) }
        let displayChunks = rawChunks.map {
            DialogCapabilities.plainText(from: TextPrettifier.prettify($0))
        }
        Log.info("[TTS] \(text.count) chars -> \(rawChunks.count) chunks (\(engine.rawValue))")
        let showDialog = ConfigManager.showTTSDialog
        if showDialog { TTSDialog.shared.show(text: text, chunks: rawChunks, playbackRate: rate) }
        lastSession = LastSession(
            text: text,
            rawChunks: rawChunks,
            chunks: speechChunks,
            displayChunks: displayChunks
        )
        resetPlaybackCache()
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
        chunks: [String],
        api: GroqAPIClient,
        voice: String,
        model: String,
        showDialog: Bool,
        dialogIndices: [Int]? = nil
    ) {
        cancelOutstandingFetches(reason: "replacing fetch set")
        let engine = ConfigManager.ttsEngine(for: model) ?? ConfigManager.selectedTTSEngine
        let maxConcurrent = ConfigManager.ttsFetchConcurrency(for: engine)
        Log.info("[TTS] launching \(chunks.count) fetches (max \(maxConcurrent) concurrent, \(engine.rawValue))")
        let gate = FetchGate(limit: maxConcurrent)
        for (index, chunk) in chunks.enumerated() {
            let dialogIndex = dialogIndices?[safe: index] ?? index
            let cacheable = isCompleteDialogChunk(chunk, dialogIndex: dialogIndex)
            if cacheable, let cached = cachedWAV(dialogIndex: dialogIndex) {
                fetchTasks[index] = Task {
                    if showDialog {
                        await MainActor.run { TTSDialog.shared.enableChunk(dialogIndex) }
                    }
                    Log.debug("[TTS] chunk \(index) reused from session cache (\(cached.count) bytes)")
                    return cached
                }
                continue
            }

            fetchTasks[index] = Task {
                await gate.acquire()
                defer { Task { await gate.release() } }

                var lastError: Error?
                for attempt in 1...2 {
                    do {
                        let data = try await api.speechData(text: chunk, voice: voice, model: model)
                        if showDialog {
                            await MainActor.run { TTSDialog.shared.enableChunk(dialogIndex) }
                        }
                        if cacheable {
                            rememberWAV(data, dialogIndex: dialogIndex)
                        }
                        Log.debug("[TTS] chunk \(index) fetched (\(data.count) bytes)")
                        return data
                    } catch {
                        if Task.isCancelled || isBenignCancellation(error) {
                            throw CancellationError()
                        }
                        lastError = error
                        if attempt < 2 {
                            Log.info("[TTS] chunk \(index) retry after: \(error.localizedDescription)")
                            try? await Task.sleep(for: .milliseconds(300))
                        }
                    }
                }
                throw lastError ?? NSError(domain: "TTS", code: -1)
            }
        }
    }

    private static func cancelFetchTasks() {
        for task in fetchTasks.values {
            task.cancel()
        }
    }

    private static func resetPlaybackCache() {
        audioCacheLock.lock()
        cachedWAVByDialogIndex.removeAll()
        cachedTimedWordsByDialogIndex.removeAll()
        audioCacheLock.unlock()
    }

    private static func cachedWAV(dialogIndex: Int) -> Data? {
        audioCacheLock.lock()
        let data = cachedWAVByDialogIndex[dialogIndex]
        audioCacheLock.unlock()
        return data
    }

    private static func rememberWAV(_ data: Data, dialogIndex: Int) {
        audioCacheLock.lock()
        cachedWAVByDialogIndex[dialogIndex] = data
        audioCacheLock.unlock()
    }

    private static func cachedTimedWords(dialogIndex: Int) -> [TimedDialogWord]? {
        audioCacheLock.lock()
        let words = cachedTimedWordsByDialogIndex[dialogIndex]
        audioCacheLock.unlock()
        return words
    }

    private static func rememberTimedWords(_ words: [TimedDialogWord], dialogIndex: Int) {
        guard !words.isEmpty else { return }
        audioCacheLock.lock()
        cachedTimedWordsByDialogIndex[dialogIndex] = words
        audioCacheLock.unlock()
    }

    private static func cachedWordStartTime(
        dialogIndex: Int,
        wordIndex: Int,
        wavData: Data
    ) -> TimeInterval {
        if let exact = cachedTimedWords(dialogIndex: dialogIndex)?
            .first(where: { $0.wordIndex == wordIndex }) {
            return max(0, exact.start - 0.035)
        }

        guard let session = lastSession,
              session.displayChunks.indices.contains(dialogIndex) else {
            return 0
        }

        let duration = AudioProcessor.wavDuration(wavData) ?? 0
        let totalWordCount = WordJumpText.wordCount(in: session.displayChunks[dialogIndex])
        guard duration > 0, totalWordCount > 0 else { return 0 }
        let clampedWord = min(max(0, wordIndex), max(0, totalWordCount - 1))
        let progress = Double(clampedWord) / Double(max(1, totalWordCount))
        return max(0, min(duration * progress, duration - 0.05))
    }

    private static func isCompleteDialogChunk(_ chunk: String, dialogIndex: Int) -> Bool {
        guard let session = lastSession,
              session.chunks.indices.contains(dialogIndex) else {
            return false
        }
        return session.chunks[dialogIndex] == chunk
    }

    private static func setPlaybackContext(dialogIndex: Int, wordTracker: LiveWordTracker?) {
        playbackContextLock.lock()
        playbackContext = PlaybackContext(dialogIndex: dialogIndex, wordTracker: wordTracker)
        playbackContextLock.unlock()
    }

    private static func clearPlaybackContext(dialogIndex: Int) {
        playbackContextLock.lock()
        if playbackContext?.dialogIndex == dialogIndex {
            playbackContext = nil
        }
        playbackContextLock.unlock()
    }

    // MARK: - Play from cache

    private static func playFromCache(
        startAt: Int, api: GroqAPIClient, player: AudioPlayer, rate: Float,
        usage: UsageTracker, preview: String, showDialog: Bool,
        startTime: TimeInterval = 0,
        chunksOverride: [String]? = nil,
        highlightIndices: [Int]? = nil,
        wordStartOffsets: [Int]? = nil
    ) async throws -> Data {
        let chunks = chunksOverride ?? lastSession?.chunks ?? []
        guard startAt < chunks.count else { return Data() }
        var wavChunks: [Data] = []
        wavChunks.reserveCapacity(chunks.count - startAt)
        let session = lastSession
        let highlightPlans = makeHighlightPlans(
            chunkCount: chunks.count,
            highlightIndices: highlightIndices,
            wordStartOffsets: wordStartOffsets
        )
        let alignmentMode = showDialog ? TTSWordAlignmentService.preferredAlignmentMode() : nil
        let alignmentGate = FetchGate(limit: 1)
        let alignmentTasks: [Task<[TimedDialogWord], Never>?] = (0..<chunks.count).map { index in
            guard let alignmentMode,
                  let session,
                  index < highlightPlans.count,
                  let highlightPlan = highlightPlans[index],
                  session.displayChunks.indices.contains(highlightPlan.dialogIndex),
                  let fetchTask = fetchTasks[index] else {
                return nil
            }
            let displayText = session.displayChunks[highlightPlan.dialogIndex]
            let spokenText = chunks[index]
            return Task {
                await alignmentGate.acquire()
                defer { Task { await alignmentGate.release() } }
                do {
                    let wavData = try await fetchTask.value
                    return await TTSWordAlignmentService.alignChunk(
                        spokenText: spokenText,
                        displayText: displayText,
                        startWordIndex: highlightPlan.startWordIndex,
                        wavData: wavData,
                        api: api,
                        mode: alignmentMode
                    )
                } catch {
                    Log.debug("[TTS ALIGN] chunk \(index) fetch/alignment setup failed: \(error.localizedDescription)")
                    return []
                }
            }
        }
        defer {
            alignmentTasks.forEach { $0?.cancel() }
        }

        for i in startAt..<chunks.count {
            try Task.checkCancellation()
            let wavData: Data
            if let task = fetchTasks[i] { wavData = try await task.value }
            else {
                if Task.isCancelled || player.cancelled {
                    Log.info("[TTS] playback loop stopped before chunk \(i) — fetch task was cancelled")
                } else {
                    Log.error("[TTS] no fetch task for chunk \(i)")
                }
                break
            }
            guard !wavData.isEmpty else { break }
            try Task.checkCancellation()

            wavChunks.append(wavData)
            usage.logUsage(kind: "tts", chars: chunks[i].count)
            NotificationHelper.sendStatus("\u{1F50A} Speaking \(i + 1)/\(chunks.count)...", subtitle: preview)
            let highlightPlan = highlightPlans.indices.contains(i) ? highlightPlans[i] : nil
            let offset: TimeInterval = (i == startAt) ? startTime : 0
            let dialogIndex = highlightPlan?.dialogIndex ?? highlightIndices?[safe: i] ?? i
            if showDialog {
                await MainActor.run {
                    TTSDialog.shared.setActiveChunk(dialogIndex)
                    TTSDialog.shared.setActiveWord(dialogIndex: dialogIndex, wordIndex: nil)
                }
            }

            let wordTracker = highlightPlan.map {
                LiveWordTracker(
                    startWordIndex: $0.startWordIndex,
                    playableWordCount: $0.playableWordCount,
                    startTime: offset
                )
            }
            let alignmentApplier: Task<Void, Never>? =
                if let wordTracker,
                   alignmentTasks.indices.contains(i),
                   let alignmentTask = alignmentTasks[i] {
                    Task {
                        let exactWords = await alignmentTask.value
                        guard !Task.isCancelled, !exactWords.isEmpty else { return }
                        wordTracker.applyExactWords(exactWords)
                        rememberTimedWords(exactWords, dialogIndex: dialogIndex)
                        Log.debug("[TTS ALIGN] chunk \(i) exact timings ready (\(exactWords.count) words)")
                    }
                } else {
                    nil
                }
            var lastHighlightedWordIndex: Int?
            setPlaybackContext(dialogIndex: dialogIndex, wordTracker: wordTracker)
            await player.play(
                data: wavData,
                rate: rate,
                startAt: offset,
                onProgress: { snapshot in
                    guard showDialog else { return }
                    guard let wordIndex = wordTracker?.currentWordIndex(
                        currentTime: snapshot.currentTime,
                        duration: snapshot.duration
                    ) else { return }
                    guard wordIndex != lastHighlightedWordIndex else { return }
                    lastHighlightedWordIndex = wordIndex
                    Task { @MainActor in
                        TTSDialog.shared.setActiveWord(
                            dialogIndex: dialogIndex,
                            wordIndex: wordIndex
                        )
                    }
                }
            )
            clearPlaybackContext(dialogIndex: dialogIndex)
            alignmentApplier?.cancel()
            if alignmentTasks.indices.contains(i) {
                alignmentTasks[i]?.cancel()
            }
            if player.cancelled { break }
        }
        return AudioProcessor.concatenateWAVFiles(wavChunks) ?? Data()
    }

    private static func makeHighlightPlans(
        chunkCount: Int,
        highlightIndices: [Int]?,
        wordStartOffsets: [Int]?
    ) -> [ChunkHighlightPlan?] {
        guard let session = lastSession else { return [] }

        return (0..<chunkCount).map { index in
            let dialogIndex = highlightIndices?[safe: index] ?? index
            guard session.displayChunks.indices.contains(dialogIndex) else { return nil }
            let totalWordCount = WordJumpText.wordCount(in: session.displayChunks[dialogIndex])
            guard totalWordCount > 0 else { return nil }
            let startWordIndex = min(max(0, wordStartOffsets?[safe: index] ?? 0), totalWordCount - 1)
            let playableWordCount = max(0, totalWordCount - startWordIndex)
            guard playableWordCount > 0 else { return nil }
            return ChunkHighlightPlan(
                dialogIndex: dialogIndex,
                startWordIndex: startWordIndex,
                playableWordCount: playableWordCount
            )
        }
    }

    // MARK: - Errors

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

    private static func isBenignCancellation(_ err: Error) -> Bool {
        if err is CancellationError { return true }
        let ns = err as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return true }
        return ns.localizedDescription
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "cancelled"
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
