import Foundation

/// Thin HTTP client for the local TTS/STT servers this app spawns.
/// The historical class name is kept so existing call sites do not need to
/// change, but the implementation is now entirely local-only.
final class GroqAPIClient: @unchecked Sendable {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.httpAdditionalHeaders = ["Connection": "keep-alive"]
        self.session = URLSession(configuration: config)
    }

    private func multipartRequest(
        url: URL,
        wavData: Data,
        fields: [(String, String)],
        timeout: TimeInterval
    ) -> URLRequest {
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = timeout

        var body = Data()
        func append(_ string: String) {
            body.append(string.data(using: .utf8)!)
        }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)--\r\n")
        request.httpBody = body
        return request
    }

    private func checkedData(
        for request: URLRequest,
        logTag: String,
        errorPrefix: String
    ) async throws -> Data {
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            Log.error("[\(logTag)] HTTP \(http.statusCode): \(body)")
            throw NSError(
                domain: "GroqTalk",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "\(errorPrefix) \(http.statusCode): \(body)"]
            )
        }

        return data
    }

    // MARK: - Parakeet STT via mlx_audio.server (port 8723, shared with Kokoro TTS)

    func transcribeMLXAudio(
        wavData: Data,
        language: String = "en",
        model: String = ConfigManager.parakeetModel
    ) async throws -> String {
        try await transcribeMLXAudioDetails(wavData: wavData, language: language, model: model, verbose: false).text
    }

    func transcribeMLXAudioDetails(
        wavData: Data,
        language: String = "en",
        model: String = ConfigManager.parakeetModel,
        verbose: Bool = true,
        timeout: TimeInterval = 120
    ) async throws -> StructuredTranscript {
        let request = multipartRequest(
            url: URL(string: "\(ConfigManager.sttMLXAudioURL)/v1/audio/transcriptions")!,
            wavData: wavData,
            fields: [
            ("model", model),
            ("language", language),
            ("verbose", verbose ? "true" : "false"),
            ],
            timeout: timeout
        )
        let data = try await checkedData(for: request, logTag: "STT PARAKEET", errorPrefix: "Parakeet error")
        return StructuredTranscriptBuilder.fromNDJSON(data)
    }

    // MARK: - Dedicated Whisper via whisper-server (8724 / 8725)

    func transcribeWhisperServer(
        wavData: Data,
        language: String = "en",
        baseURL: String
    ) async throws -> String {
        try await transcribeWhisperServerDetails(
            wavData: wavData,
            language: language,
            baseURL: baseURL,
            verbose: false
        ).text
    }

    func transcribeWhisperServerDetails(
        wavData: Data,
        language: String = "en",
        baseURL: String,
        verbose: Bool = true,
        timeout: TimeInterval = 180
    ) async throws -> StructuredTranscript {
        var fields = [
            ("language", language),
            ("response_format", verbose ? "verbose_json" : "json"),
            ("temperature", "0.0"),
        ]
        let prompt = ConfigManager.loadDictionary()
        if !prompt.isEmpty {
            fields.append(("prompt", prompt))
        }
        let request = multipartRequest(
            url: URL(string: "\(baseURL)/inference")!,
            wavData: wavData,
            fields: fields,
            timeout: timeout
        )
        let data = try await checkedData(for: request, logTag: "STT WHISPER", errorPrefix: "Whisper error")
        return StructuredTranscriptBuilder.fromNDJSON(data)
    }

    // MARK: - Shared TTS via mlx_audio.server (port 8723)

    func speechData(text: String, voice: String, model: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(ConfigManager.ttsBaseURL)/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let engine = ConfigManager.ttsEngine(for: model) ?? ConfigManager.selectedTTSEngine
        let fallbackVoice = ConfigManager.ttsEngineEntry(engine).defaultVoice
        let runtimeVoice = KokoroVoiceResolver.runtimeVoiceSpecifier(
            voice: voice,
            model: model,
            fallbackVoice: fallbackVoice
        )
        if runtimeVoice != voice {
            Log.info("[TTS API] resolved voice \(voice) locally")
        }

        var payload: [String: Any] = [
            "model": model,
            "input": text,
            "voice": runtimeVoice,
            "response_format": "wav"
        ]
        let decoding = ConfigManager.ttsDecodingOptions(for: engine)
        if let temperature = decoding.temperature { payload["temperature"] = temperature }
        if let topP = decoding.topP { payload["top_p"] = topP }
        if let topK = decoding.topK { payload["top_k"] = topK }
        if let repetitionPenalty = decoding.repetitionPenalty {
            payload["repetition_penalty"] = repetitionPenalty
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await checkedData(for: request, logTag: "TTS API", errorPrefix: "TTS API error")
    }
}
