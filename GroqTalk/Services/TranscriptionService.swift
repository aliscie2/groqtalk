import AVFoundation
import Foundation

enum TranscriptionService {

    static func process(
        buffers: [AVAudioPCMBuffer], api: GroqAPIClient, enhance: Bool,
        history: HistoryManager, usage: UsageTracker, sttMode: ConfigManager.STTMode = .groqCloud
    ) async {
        let start = CFAbsoluteTimeGetCurrent()
        Log.info("[STT] final pipeline started, buffers=\(buffers.count)")

        do {
            guard !buffers.isEmpty else {
                NotificationHelper.sendStatus("\u{274C} No audio captured.")
                return
            }

            NotificationHelper.sendStatus("\u{231B} Processing audio...")

            let (wavData, duration) = AudioProcessor.prepareForWhisper(buffers)

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

            // Now try transcription
            NotificationHelper.sendStatus("\u{231B} Transcribing...")

            let rawText: String
            switch sttMode {
            case .groqCloud:
                rawText = try await transcribeWhisper(wavData: wavData, duration: duration, api: api, usage: usage)
            case .localSmall:
                rawText = try await transcribeLocal(wavData: wavData, duration: duration, api: api, baseURL: ConfigManager.sttBaseURL)
            case .localLarge:
                rawText = try await transcribeLocal(wavData: wavData, duration: duration, api: api, baseURL: ConfigManager.sttLargeURL)
            }
            guard !rawText.isEmpty else { return }

            if enhance && rawText.split(separator: " ").count >= ConfigManager.llmSkipWordLimit {
                NotificationHelper.sendStatus("\u{231B} Enhancing...")
            }
            let cleanedText = try await enhanceTranscript(rawText: rawText, enhance: enhance, api: api, usage: usage)

            // Mark pending as completed
            history.completePending(timestamp: pendingTs, transcript: rawText, cleaned: cleanedText)

            NotificationHelper.sendStatus("\u{2705} Text ready", subtitle: String(cleanedText.prefix(60)))

            ClipboardService.write(cleanedText)
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
        timestamp: String, api: GroqAPIClient, enhance: Bool,
        history: HistoryManager, usage: UsageTracker, sttMode: ConfigManager.STTMode = .groqCloud
    ) async {
        guard let wavData = history.getPendingWav(timestamp: timestamp) else {
            NotificationHelper.sendStatus("\u{274C} Recording not found.")
            return
        }

        let duration = Double(wavData.count - 44) / Double(ConfigManager.sampleRate * 2)

        do {
            NotificationHelper.sendStatus("\u{231B} Retrying transcription...")

            let rawText: String
            switch sttMode {
            case .groqCloud:
                rawText = try await transcribeWhisper(wavData: wavData, duration: duration, api: api, usage: usage)
            case .localSmall:
                rawText = try await transcribeLocal(wavData: wavData, duration: duration, api: api, baseURL: ConfigManager.sttBaseURL)
            case .localLarge:
                rawText = try await transcribeLocal(wavData: wavData, duration: duration, api: api, baseURL: ConfigManager.sttLargeURL)
            }
            guard !rawText.isEmpty else {
                NotificationHelper.sendStatus("\u{274C} Empty transcription.")
                return
            }

            let cleanedText: String
            if enhance && rawText.split(separator: " ").count >= ConfigManager.llmSkipWordLimit {
                NotificationHelper.sendStatus("\u{231B} Enhancing...")
                cleanedText = try await enhanceTranscript(rawText: rawText, enhance: enhance, api: api, usage: usage)
            } else {
                cleanedText = rawText
            }

            history.completePending(timestamp: timestamp, transcript: rawText, cleaned: cleanedText)

            ClipboardService.write(cleanedText)
            try? await Task.sleep(for: .milliseconds(50))
            autoPaste()

            NotificationHelper.sendStatus("\u{2705} Retry succeeded!", subtitle: String(cleanedText.prefix(60)))
            Log.info("[STT] retry succeeded for \(timestamp)")

            try? await Task.sleep(for: .seconds(3))
            NotificationHelper.clearStatus()

        } catch {
            Log.error("[STT] retry failed: \(error)")
            NotificationHelper.sendStatus("\u{274C} Retry failed — try again later.")
        }
    }

    // MARK: - Local Whisper

    private static func transcribeLocal(
        wavData: Data, duration: Double, api: GroqAPIClient, baseURL: String
    ) async throws -> String {
        let start = CFAbsoluteTimeGetCurrent()
        Log.info("[STT] sending to local Whisper server (\(baseURL))...")
        let text = try await api.transcribeLocal(wavData: wavData, baseURL: baseURL)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        Log.info("[STT] Local Whisper done in \(String(format: "%.2f", elapsed))s — \(text.count) chars")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Whisper

    private static func transcribeWhisper(
        wavData: Data, duration: Double, api: GroqAPIClient, usage: UsageTracker
    ) async throws -> String {
        let start = CFAbsoluteTimeGetCurrent()
        Log.info("[STT] sending to Groq Whisper (\(ConfigManager.whisperModel))...")
        let text = try await api.transcribe(wavData: wavData)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        Log.info("[STT] Whisper done in \(String(format: "%.2f", elapsed))s — \(text.count) chars")
        usage.logUsage(kind: "whisper", audioDuration: duration)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - LLM Enhance

    private static func enhanceTranscript(
        rawText: String, enhance: Bool, api: GroqAPIClient, usage: UsageTracker
    ) async throws -> String {
        guard enhance else {
            Log.info("[STT] enhance OFF — skipping LLM")
            return rawText
        }

        let words = rawText.split(separator: " ").count
        guard words >= ConfigManager.llmSkipWordLimit else {
            Log.info("[STT] only \(words) words — skipping LLM")
            return rawText
        }

        let start = CFAbsoluteTimeGetCurrent()
        let result = try await api.chatCompletion(
            system: ConfigManager.llmSystemPrompt,
            user: rawText,
            model: ConfigManager.llmModel
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        Log.info("[STT] LLM done in \(String(format: "%.2f", elapsed))s")
        usage.logUsage(kind: "llm", tokens: result.usage?.totalTokens ?? 0)
        return result.choices.first?.message.content ?? rawText
    }

    // MARK: - Auto-paste

    private static func autoPaste() {
        guard AccessibilityChecker.isTrusted() else {
            Log.info("[STT] skipping paste — no Accessibility")
            return
        }
        ClipboardService.paste()
    }

    // MARK: - Live transcription

    static func liveLoop(recorder: AudioRecorder, api: GroqAPIClient, usage: UsageTracker, sttMode: ConfigManager.STTMode = .groqCloud) async {
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
                let text: String
                switch sttMode {
                case .groqCloud:
                    text = try await api.transcribe(wavData: wavData)
                case .localSmall:
                    text = try await api.transcribeLocal(wavData: wavData, baseURL: ConfigManager.sttBaseURL)
                case .localLarge:
                    text = try await api.transcribeLocal(wavData: wavData, baseURL: ConfigManager.sttLargeURL)
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                ClipboardService.write(trimmed)
                partsCollected += 1
            } catch {
                Log.error("[LIVE] partial transcription error: \(error)")
            }
        }
        Log.info("[LIVE] thread stopped — \(partsCollected) parts collected")
    }
}
