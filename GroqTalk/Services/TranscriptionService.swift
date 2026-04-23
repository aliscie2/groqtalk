import AVFoundation
import Foundation

enum TranscriptionService {

    private typealias TranscriptionOutcome = (
        transcript: StructuredTranscript,
        rawText: String,
        cleanedText: String
    )

    static func process(
        buffers: [AVAudioPCMBuffer], api: GroqAPIClient,
        history: HistoryManager, usage: UsageTracker,
        sttMode: ConfigManager.STTMode = .parakeet,
        insertionTarget: ClipboardService.InsertionTarget? = nil
    ) async {
        let start = CFAbsoluteTimeGetCurrent()
        Log.info("[STT] final pipeline started, buffers=\(buffers.count)")

        do {
            guard !buffers.isEmpty else {
                NotificationHelper.sendStatus("\u{274C} No audio captured.")
                return
            }

            NotificationHelper.sendStatus("\u{231B} Processing audio...")

            let (wavDataRaw, duration) = AudioProcessor.prepareForWhisper(buffers)

            guard duration >= 0.5 else {
                NotificationHelper.sendStatus("\u{274C} Recording too short.")
                return
            }

            let rawAudio = AudioProcessor.concatenate(buffers)
            guard !AudioProcessor.isAudioSilent(rawAudio) else {
                NotificationHelper.sendStatus("\u{274C} No sound detected.")
                return
            }

            // Save recording immediately — before API call
            let trimmedAudio = AudioProcessor.trimSilence(rawAudio)
            let replayWav = AudioProcessor.encodeWAV(trimmedAudio)
            let pendingTs = history.savePendingRecording(wavBytes: replayWav)

            let wavData = await maybeDenoise(wavDataRaw)

            NotificationHelper.sendStatus("\u{231B} Transcribing...")
            let outcome = try await transcribeAndClean(mode: sttMode, wavData: wavData, api: api)
            await finalizeTranscription(
                timestamp: pendingTs,
                outcome: outcome,
                duration: duration,
                history: history,
                usage: usage,
                insertionTarget: insertionTarget,
                successStatus: "\u{2705} Text ready"
            )

            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
            Log.info("[STT] done in \(elapsed)s")
            NotificationHelper.clearStatus()

        } catch is CancellationError {
            NotificationHelper.clearStatus()
        } catch {
            Log.error("[STT] error: \(error)")
            NotificationHelper.sendStatus("\u{274C} Failed — recording saved. Retry from menu.")
        }
    }

    /// Retry transcription for a pending recording
    static func retryPending(
        timestamp: String, api: GroqAPIClient,
        history: HistoryManager, usage: UsageTracker, sttMode: ConfigManager.STTMode = .parakeet
    ) async {
        guard let wavDataRaw = history.getPendingWav(timestamp: timestamp) else {
            NotificationHelper.sendStatus("\u{274C} Recording not found.")
            return
        }

        let duration = Double(wavDataRaw.count - 44) / Double(ConfigManager.sampleRate * 2)

        do {
            NotificationHelper.sendStatus("\u{231B} Retrying transcription...")

            let wavData = await maybeDenoise(wavDataRaw)

            let outcome = try await transcribeAndClean(mode: sttMode, wavData: wavData, api: api)
            await finalizeTranscription(
                timestamp: timestamp,
                outcome: outcome,
                duration: duration,
                history: history,
                usage: usage,
                insertionTarget: nil,
                successStatus: "\u{2705} Retry succeeded!"
            )
            Log.info("[STT] retry succeeded for \(timestamp)")

            try? await Task.sleep(for: .seconds(3))
            NotificationHelper.clearStatus()

        } catch {
            Log.error("[STT] retry failed: \(error)")
            NotificationHelper.sendStatus("\u{274C} Retry failed — try again later.")
        }
    }

    // MARK: - Live transcription

    static func liveLoop(
        recorder: AudioRecorder,
        api: GroqAPIClient,
        sttMode: ConfigManager.STTMode = .parakeet,
        onPartial: ((String) -> Void)? = nil
    ) async {
        Log.info("[LIVE] live transcription started")
        var partsCollected = 0
        var lastEmittedText = ""
        let interval: UInt64 = 900_000_000
        let rollingWindowSeconds = 2.4

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled else { break }

            let buffers = recorder.liveBuffers(maxDuration: rollingWindowSeconds)
            guard buffers.count >= 3 else { continue }

            let (wavData, duration) = AudioProcessor.prepareForWhisper(buffers)
            guard duration >= 0.55 else { continue }

            do {
                let transcript = try await transcribe(mode: sttMode, wavData: wavData, api: api)
                let cleanedText = TranscriptPostProcessor.clean(transcript)
                guard !cleanedText.isEmpty else { continue }
                guard cleanedText != lastEmittedText else { continue }
                lastEmittedText = cleanedText
                onPartial?(cleanedText)
                partsCollected += 1
            } catch {
                Log.error("[LIVE] partial transcription error: \(error)")
            }
        }
        Log.info("[LIVE] thread stopped — \(partsCollected) parts collected")
    }

    // MARK: - Helpers

    private static func transcribeAndClean(
        mode: ConfigManager.STTMode,
        wavData: Data,
        api: GroqAPIClient
    ) async throws -> TranscriptionOutcome {
        let transcript = try await transcribeWithRecovery(mode: mode, wavData: wavData, api: api)
        let rawText = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedText = TranscriptPostProcessor.clean(transcript)
        guard !rawText.isEmpty, !cleanedText.isEmpty else {
                NotificationHelper.sendStatus("\u{274C} Empty transcription.")
            throw NSError(domain: "GroqTalk.STT", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Empty transcription."
            ])
        }
        return (transcript, rawText, cleanedText)
    }

    private static func finalizeTranscription(
        timestamp: String,
        outcome: TranscriptionOutcome,
        duration: Double,
        history: HistoryManager,
        usage: UsageTracker,
        insertionTarget: ClipboardService.InsertionTarget?,
        successStatus: String
    ) async {
        usage.logUsage(kind: "stt", audioDuration: duration)

        history.completePending(
            timestamp: timestamp,
            transcript: outcome.rawText,
            cleaned: outcome.cleanedText,
            structuredTranscript: outcome.transcript.hasTimings ? outcome.transcript : nil
        )

        DictationUndoManager.recordPastedText(outcome.cleanedText)
        try? await Task.sleep(for: .milliseconds(50))
        autoPaste(outcome.cleanedText, target: insertionTarget)
        NotificationHelper.sendStatus(successStatus, subtitle: String(outcome.cleanedText.prefix(60)))
    }

    private static func transcribe(
        mode: ConfigManager.STTMode,
        wavData: Data,
        api: GroqAPIClient
    ) async throws -> StructuredTranscript {
        let start = CFAbsoluteTimeGetCurrent()
        let transcript: StructuredTranscript

        switch mode {
        case .parakeet:
            let model = ConfigManager.parakeetModel
            Log.info("[STT] sending to \(mode.rawValue) (\(ConfigManager.sttServerURL(for: mode)))...")
            transcript = try await api.transcribeMLXAudioDetails(wavData: wavData, model: model, verbose: true)
        case .whisperSmall, .whisperLarge:
            let baseURL = ConfigManager.sttServerURL(for: mode)
            Log.info("[STT] sending to \(mode.rawValue) (\(baseURL))...")
            transcript = try await api.transcribeWhisperServerDetails(wavData: wavData, baseURL: baseURL, verbose: true)
        }

        let trimmed = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        Log.info("[STT] \(mode.rawValue) done in \(String(format: "%.2f", elapsed))s — \(trimmed.count) chars")
        return StructuredTranscript(text: trimmed, sentences: transcript.sentences)
    }

    private static func transcribeWithRecovery(
        mode: ConfigManager.STTMode,
        wavData: Data,
        api: GroqAPIClient
    ) async throws -> StructuredTranscript {
        do {
            return try await transcribe(mode: mode, wavData: wavData, api: api)
        } catch {
            guard mode == .parakeet, shouldRetrySharedServer(error) else { throw error }
            Log.info("[STT] shared Parakeet server failed — waiting for auto-restart and retrying once")
            NotificationHelper.sendStatus("\u{231B} Restarting speech engine...")
            try? await Task.sleep(for: .milliseconds(2400))
            return try await transcribe(mode: mode, wavData: wavData, api: api)
        }
    }

    private static func shouldRetrySharedServer(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotParseResponse,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost:
                return true
            default:
                break
            }
        }

        let message = nsError.localizedDescription.lowercased()
        return message.contains("cannot parse response")
            || message.contains("could not connect")
            || message.contains("network connection was lost")
    }

    private static func maybeDenoise(_ wavDataRaw: Data) async -> Data {
        guard ConfigManager.denoiseBeforeSTT else { return wavDataRaw }
        NotificationHelper.sendStatus("\u{231B} Denoising audio...")
        return await AudioSeparator.separate(wavData: wavDataRaw)
    }

    private static func autoPaste(_ text: String, target: ClipboardService.InsertionTarget?) {
        guard AccessibilityChecker.isTrusted() else {
            Log.info("[STT] skipping paste — no Accessibility")
            return
        }
        _ = ClipboardService.insertText(text, target: target)
    }
}
