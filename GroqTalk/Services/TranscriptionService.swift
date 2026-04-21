import AVFoundation
import Foundation

enum TranscriptionService {

    static func process(
        buffers: [AVAudioPCMBuffer], api: GroqAPIClient,
        history: HistoryManager, usage: UsageTracker, sttMode: ConfigManager.STTMode = .localSmall
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
            let rawText = try await transcribe(mode: sttMode, wavData: wavData, api: api)
            guard !rawText.isEmpty else { return }

            usage.logUsage(kind: "stt", audioDuration: duration)

            history.completePending(timestamp: pendingTs, transcript: rawText, cleaned: rawText)

            NotificationHelper.sendStatus("\u{2705} Text ready", subtitle: String(rawText.prefix(60)))

            ClipboardService.write(rawText)
            try? await Task.sleep(for: .milliseconds(50))
            autoPaste()

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
        history: HistoryManager, usage: UsageTracker, sttMode: ConfigManager.STTMode = .localSmall
    ) async {
        guard let wavDataRaw = history.getPendingWav(timestamp: timestamp) else {
            NotificationHelper.sendStatus("\u{274C} Recording not found.")
            return
        }

        let duration = Double(wavDataRaw.count - 44) / Double(ConfigManager.sampleRate * 2)

        do {
            NotificationHelper.sendStatus("\u{231B} Retrying transcription...")

            let wavData = await maybeDenoise(wavDataRaw)

            let rawText = try await transcribe(mode: sttMode, wavData: wavData, api: api)
            guard !rawText.isEmpty else {
                NotificationHelper.sendStatus("\u{274C} Empty transcription.")
                return
            }

            usage.logUsage(kind: "stt", audioDuration: duration)

            history.completePending(timestamp: timestamp, transcript: rawText, cleaned: rawText)

            ClipboardService.write(rawText)
            try? await Task.sleep(for: .milliseconds(50))
            autoPaste()

            NotificationHelper.sendStatus("\u{2705} Retry succeeded!", subtitle: String(rawText.prefix(60)))
            Log.info("[STT] retry succeeded for \(timestamp)")

            try? await Task.sleep(for: .seconds(3))
            NotificationHelper.clearStatus()

        } catch {
            Log.error("[STT] retry failed: \(error)")
            NotificationHelper.sendStatus("\u{274C} Retry failed — try again later.")
        }
    }

    // MARK: - Live transcription

    static func liveLoop(recorder: AudioRecorder, api: GroqAPIClient, usage: UsageTracker, sttMode: ConfigManager.STTMode = .localSmall) async {
        Log.info("[LIVE] live transcription started")
        var partsCollected = 0
        let interval: UInt64 = 3_000_000_000

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: interval)
            guard !Task.isCancelled else { break }

            let buffers = recorder.liveBuffers()
            guard buffers.count >= 3 else { continue }

            let (wavData, duration) = AudioProcessor.prepareForWhisper(buffers)
            guard duration >= 1.0 else { continue }

            do {
                let text = try await transcribe(mode: sttMode, wavData: wavData, api: api)
                guard !text.isEmpty else { continue }
                ClipboardService.write(text)
                partsCollected += 1
            } catch {
                Log.error("[LIVE] partial transcription error: \(error)")
            }
        }
        Log.info("[LIVE] thread stopped — \(partsCollected) parts collected")
    }

    // MARK: - Helpers

    private static func transcribe(mode: ConfigManager.STTMode, wavData: Data, api: GroqAPIClient) async throws -> String {
        let start = CFAbsoluteTimeGetCurrent()
        let text: String
        switch mode {
        case .parakeet:
            Log.info("[STT] sending to Parakeet (\(ConfigManager.sttMLXAudioURL))...")
            text = try await api.transcribeMLXAudio(wavData: wavData)
        case .localSmall:
            Log.info("[STT] sending to local Whisper small (\(ConfigManager.sttBaseURL))...")
            text = try await api.transcribeLocal(wavData: wavData, baseURL: ConfigManager.sttBaseURL)
        case .localLarge:
            Log.info("[STT] sending to local Whisper large (\(ConfigManager.sttLargeURL))...")
            text = try await api.transcribeLocal(wavData: wavData, baseURL: ConfigManager.sttLargeURL)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        Log.info("[STT] \(mode) done in \(String(format: "%.2f", elapsed))s — \(trimmed.count) chars")
        return trimmed
    }

    private static func maybeDenoise(_ wavDataRaw: Data) async -> Data {
        guard ConfigManager.denoiseBeforeSTT else { return wavDataRaw }
        NotificationHelper.sendStatus("\u{231B} Denoising audio...")
        return await AudioSeparator.separate(wavData: wavDataRaw)
    }

    private static func autoPaste() {
        guard AccessibilityChecker.isTrusted() else {
            Log.info("[STT] skipping paste — no Accessibility")
            return
        }
        ClipboardService.paste()
    }
}
