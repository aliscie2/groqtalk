import Foundation

/// Thin HTTP client for the local TTS/STT servers this app spawns.
/// All cloud paths (Groq, OpenAI) have been removed — the app is local-only.
/// Class name is kept as `GroqAPIClient` for binary-compat with existing call
/// sites; functionally it no longer touches any cloud service.
final class GroqAPIClient: @unchecked Sendable {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.httpAdditionalHeaders = ["Connection": "keep-alive"]
        self.session = URLSession(configuration: config)
    }

    // MARK: - Local Whisper (whisper.cpp on 8724/8725)

    func transcribeLocal(
        wavData: Data,
        language: String = "en",
        baseURL: String = ConfigManager.sttBaseURL
    ) async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)/inference")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        var body = Data()
        func append(_ str: String) { body.append(str.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        let prompt = ConfigManager.loadDictionary()
        var fields = [("language", language), ("response_format", "text"), ("temperature", "0.0")]
        if !prompt.isEmpty { fields.append(("prompt", prompt)) }
        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)--\r\n")

        request.httpBody = body
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            Log.error("[STT LOCAL] HTTP \(http.statusCode): \(body)")
            throw NSError(domain: "GroqTalk", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Local Whisper error \(http.statusCode): \(body)"])
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Parakeet STT via mlx_audio.server (port 8723, shared with Kokoro TTS)

    func transcribeMLXAudio(
        wavData: Data,
        language: String = "en",
        model: String = ConfigManager.parakeetModel
    ) async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(ConfigManager.sttMLXAudioURL)/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        var body = Data()
        func append(_ str: String) { body.append(str.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        let fields = [("model", model), ("language", language)]
        for (key, value) in fields {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"\(key)\"\r\n\r\n")
            append("\(value)\r\n")
        }
        append("--\(boundary)--\r\n")

        request.httpBody = body
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            Log.error("[STT PARAKEET] HTTP \(http.statusCode): \(body)")
            throw NSError(domain: "GroqTalk", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Parakeet error \(http.statusCode): \(body)"])
        }

        // mlx_audio.server streams JSON lines; join and pull final accumulated
        let raw = String(data: data, encoding: .utf8) ?? ""
        var finalText = ""
        for line in raw.split(separator: "\n") {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
            if let acc = obj["accumulated"] as? String { finalText = acc }
            else if let t = obj["text"] as? String { finalText += t }
        }
        if finalText.isEmpty, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let t = obj["text"] as? String {
            finalText = t
        }
        return finalText
    }

    // MARK: - Kokoro TTS via mlx_audio.server (port 8723)

    func speechData(text: String, voice: String, model: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(ConfigManager.ttsBaseURL)/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let payload: [String: Any] = [
            "model": model,
            "input": text,
            "voice": voice,
            "response_format": "wav"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            Log.error("[TTS API] HTTP \(http.statusCode): \(body)")
            throw NSError(domain: "GroqTalk", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "TTS API error \(http.statusCode): \(body)"])
        }

        return data
    }
}
