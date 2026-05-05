import AVFoundation
import Foundation

enum TranscriptionService {

    private typealias TranscriptionOutcome = (
        transcript: StructuredTranscript,
        rawText: String,
        cleanedText: String
    )
    static var recoverSharedParakeetServer: (@Sendable (String) async -> Void)?

    static func noteSharedParakeetServerRestarted() {
        SharedSpeechServerHealth.noteRestart()
    }

    /// Run the full STT pipeline. Returns the cleaned transcript text on
    /// success, or nil on any failure / empty audio. When `autoInsert` is
    /// true (legacy default), the cleaned text is also pasted into
    /// `insertionTarget`. When false, the caller is responsible for the paste
    /// (used by the editable-dialog flow).
    @discardableResult
    static func process(
        buffers: [AVAudioPCMBuffer], api: GroqAPIClient,
        history: HistoryManager, usage: UsageTracker,
        sttMode: ConfigManager.STTMode = .parakeet,
        insertionTarget: ClipboardService.InsertionTarget? = nil,
        autoInsert: Bool = true
    ) async -> String? {
        let start = CFAbsoluteTimeGetCurrent()
        Log.info("[STT] final pipeline started, buffers=\(buffers.count)")

        do {
            guard !buffers.isEmpty else {
                NotificationHelper.sendStatus("\u{274C} No audio captured.")
                return nil
            }

            NotificationHelper.sendStatus("\u{231B} Processing audio...")

            let (wavDataRaw, duration) = AudioProcessor.prepareForWhisper(buffers)

            guard duration >= 0.5 else {
                NotificationHelper.sendStatus("\u{274C} Recording too short.")
                return nil
            }

            let rawAudio = AudioProcessor.concatenate(buffers)
            guard !AudioProcessor.isAudioSilent(rawAudio) else {
                NotificationHelper.sendStatus("\u{274C} No sound detected.")
                return nil
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
                insertionTarget: autoInsert ? insertionTarget : nil,
                successStatus: "\u{2705} Text ready",
                autoInsert: autoInsert
            )

            let elapsed = String(format: "%.1f", CFAbsoluteTimeGetCurrent() - start)
            Log.info("[STT] done in \(elapsed)s")
            NotificationHelper.clearStatus()
            return outcome.cleanedText

        } catch is CancellationError {
            NotificationHelper.clearStatus()
            return nil
        } catch {
            Log.error("[STT] error: \(error)")
            NotificationHelper.sendStatus("\u{274C} Failed — recording saved. Retry from menu.")
            return nil
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
        sessionID: Int,
        onPartial: ((LiveCaptionSnapshot) -> Void)? = nil
    ) async {
        Log.info("[LIVE] session \(sessionID) started")
        var partsCollected = 0
        var assembler = LiveTranscriptAssembler()
        let interval: UInt64 = 400_000_000
        let rollingWindowSeconds = 3.2
        let requestTimeout = liveRequestTimeout(for: sttMode)

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled else { break }
            guard recorder.isRecordingActive else {
                Log.info("[LIVE] session \(sessionID) recorder inactive — exiting")
                break
            }

            let buffers = recorder.liveBuffers(maxDuration: rollingWindowSeconds)
            guard buffers.count >= 3 else { continue }

            let (wavData, duration) = AudioProcessor.prepareForWhisper(buffers)
            guard duration >= 0.45 else { continue }

            do {
                let transcript = try await transcribe(
                    mode: sttMode,
                    wavData: wavData,
                    api: api,
                    requestTimeout: requestTimeout,
                    phase: .livePartial
                )
                guard !Task.isCancelled, recorder.isRecordingActive else {
                    Log.debug("[LIVE] session \(sessionID) cancelled before publish")
                    break
                }
                guard let snapshot = assembler.consume(transcript) else { continue }
                onPartial?(snapshot)
                partsCollected += 1
            } catch is CancellationError {
                Log.debug("[LIVE] session \(sessionID) request cancelled")
                break
            } catch {
                let nsError = error as NSError
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                    Log.debug("[LIVE] session \(sessionID) URLSession cancelled")
                    break
                }
                if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
                    Log.info(
                        "[LIVE] session \(sessionID) partial timed out after \(String(format: "%.1f", requestTimeout))s — skipping"
                    )
                    if sttMode == .parakeet,
                       let reason = SharedSpeechServerHealth.recordTimeout(phase: .livePartial) {
                        await recoverSharedParakeetServerIfNeeded(reason: reason, waitForRecovery: true)
                    }
                    continue
                }
                Log.error("[LIVE] session \(sessionID) partial transcription error: \(error)")
            }
        }
        Log.info("[LIVE] session \(sessionID) stopped — \(partsCollected) parts collected")
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
        if rawText != cleanedText {
            Log.debug("[STT CLEAN] raw=\(preview(rawText)) | cleaned=\(preview(cleanedText))")
        }
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
        successStatus: String,
        autoInsert: Bool = true
    ) async {
        usage.logUsage(kind: "stt", audioDuration: duration)

        history.completePending(
            timestamp: timestamp,
            transcript: outcome.rawText,
            cleaned: outcome.cleanedText,
            structuredTranscript: outcome.transcript.hasTimings ? outcome.transcript : nil
        )

        if autoInsert {
            DictationUndoManager.recordPastedText(outcome.cleanedText)
            try? await Task.sleep(for: .milliseconds(50))
            autoPaste(outcome.cleanedText, target: insertionTarget)
        }
        NotificationHelper.sendStatus(successStatus, subtitle: String(outcome.cleanedText.prefix(60)))
    }

    private static func transcribe(
        mode: ConfigManager.STTMode,
        wavData: Data,
        api: GroqAPIClient,
        requestTimeout: TimeInterval? = nil,
        phase: SharedSpeechServerHealthState.Phase = .finalPass
    ) async throws -> StructuredTranscript {
        let start = CFAbsoluteTimeGetCurrent()
        let transcript: StructuredTranscript

        switch mode {
        case .parakeet:
            let model = ConfigManager.parakeetModel
            Log.info("[STT] sending to \(mode.rawValue) (\(ConfigManager.sttServerURL(for: mode)))...")
            transcript = try await api.transcribeMLXAudioDetails(
                wavData: wavData,
                model: model,
                verbose: true,
                timeout: requestTimeout ?? 120
            )
        case .whisperSmall, .whisperLarge:
            let baseURL = ConfigManager.sttServerURL(for: mode)
            Log.info("[STT] sending to \(mode.rawValue) (\(baseURL))...")
            transcript = try await api.transcribeWhisperServerDetails(
                wavData: wavData,
                baseURL: baseURL,
                verbose: true,
                timeout: requestTimeout ?? 180
            )
        }

        let trimmed = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        Log.info("[STT] \(mode.rawValue) done in \(String(format: "%.2f", elapsed))s — \(trimmed.count) chars")
        if mode == .parakeet,
           let reason = SharedSpeechServerHealth.recordSuccess(duration: elapsed, phase: phase) {
            await recoverSharedParakeetServerIfNeeded(reason: reason, waitForRecovery: false)
        }
        return StructuredTranscript(text: trimmed, sentences: transcript.sentences)
    }

    private static func transcribeWithRecovery(
        mode: ConfigManager.STTMode,
        wavData: Data,
        api: GroqAPIClient
    ) async throws -> StructuredTranscript {
        do {
            return try await transcribe(mode: mode, wavData: wavData, api: api, phase: .finalPass)
        } catch {
            guard mode == .parakeet, shouldRetrySharedServer(error) else { throw error }
            let reason = sharedServerRecoveryReason(for: error)
            Log.info("[STT] shared Parakeet server failed — recovering and retrying once")
            NotificationHelper.sendStatus("\u{231B} Restarting speech engine...")
            await recoverSharedParakeetServerIfNeeded(reason: reason, waitForRecovery: true)
            return try await transcribe(mode: mode, wavData: wavData, api: api, phase: .finalPass)
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

    private static func liveRequestTimeout(for mode: ConfigManager.STTMode) -> TimeInterval {
        switch mode {
        case .parakeet:
            return 1.5
        case .whisperSmall:
            return 4.0
        case .whisperLarge:
            return 6.0
        }
    }

    private static func sharedServerRecoveryReason(for error: Error) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return SharedSpeechServerHealth.recordTimeout(phase: .finalPass)
                ?? "shared 8723 server timed out during a final STT run"
        }
        return "shared 8723 server returned a retryable STT failure (\(nsError.localizedDescription))"
    }

    private static func recoverSharedParakeetServerIfNeeded(
        reason: String,
        waitForRecovery: Bool
    ) async {
        Log.info("[STT HEALTH] requesting shared server recovery: \(reason)")
        guard let recoverSharedParakeetServer else { return }
        if waitForRecovery {
            await recoverSharedParakeetServer(reason)
        } else {
            Task.detached(priority: .utility) {
                await recoverSharedParakeetServer(reason)
            }
        }
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

    private static func preview(_ text: String, limit: Int = 180) -> String {
        let compact = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        guard compact.count > limit else { return compact }
        return String(compact.prefix(limit)) + "..."
    }
}
