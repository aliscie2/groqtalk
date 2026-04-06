import Foundation

final class GroqAPIClient: @unchecked Sendable {

    private let baseURL = "https://api.groq.com/openai/v1"
    private let session: URLSession
    private var apiKey: String { ConfigManager.shared.apiKey }

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.httpAdditionalHeaders = ["Connection": "keep-alive"]
        self.session = URLSession(configuration: config)
    }

    func listModels() async throws -> ModelsResponse {
        var request = URLRequest(url: URL(string: "\(baseURL)/models")!)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "GroqTalk", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Groq API error \(http.statusCode): \(body)"])
        }

        return try JSONDecoder().decode(ModelsResponse.self, from: data)
    }

    func transcribe(wavData: Data, model: String = ConfigManager.whisperModel, language: String = "en") async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "\(baseURL)/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func append(_ str: String) { body.append(str.data(using: .utf8)!) }

        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        append("Content-Type: audio/wav\r\n\r\n")
        body.append(wavData)
        append("\r\n")

        let prompt = ConfigManager.loadDictionary()
        var fields = [("model", model), ("language", language), ("response_format", "text")]
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
            Log.error("[STT API] HTTP \(http.statusCode): \(body)")
            throw NSError(domain: "GroqTalk", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Groq API error \(http.statusCode): \(body)"])
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    func chatCompletion(system: String, user: String, model: String = ConfigManager.llmModel) async throws -> ChatResponse {
        var request = URLRequest(url: URL(string: "\(baseURL)/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let chatReq = ChatRequest(
            model: model,
            messages: [
                ChatMessage(role: "system", content: system),
                ChatMessage(role: "user", content: user)
            ],
            temperature: 0.3
        )
        request.httpBody = try JSONEncoder().encode(chatReq)
        let (data, response) = try await session.data(for: request)

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            Log.error("[LLM API] HTTP \(http.statusCode): \(body)")
            throw NSError(domain: "GroqTalk", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "Groq API error \(http.statusCode): \(body)"])
        }

        return try JSONDecoder().decode(ChatResponse.self, from: data)
    }

    func transcribeLocal(wavData: Data, language: String = "en", baseURL: String = ConfigManager.sttBaseURL) async throws -> String {
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

        // whisper.cpp server returns JSON with "text" field
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let text = json["text"] as? String {
            return text
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func speechData(text: String, voice: String = ConfigManager.ttsVoice) async throws -> Data {
        var request = URLRequest(url: URL(string: "\(ConfigManager.ttsBaseURL)/v1/audio/speech")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let payload: [String: Any] = [
            "model": ConfigManager.ttsModel,
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
