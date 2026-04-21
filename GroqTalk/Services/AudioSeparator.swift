import Foundation

/// Calls mlx_audio.server's /v1/audio/separations endpoint to isolate the voice
/// stem from a WAV recording before sending to STT. Non-blocking: if the server
/// doesn't support separations or returns an error, the original WAV is returned
/// so transcription can still proceed.
enum AudioSeparator {

    /// Send WAV bytes to the separations endpoint and return voice-only WAV bytes.
    /// Falls back to the original input on any failure.
    static func separate(wavData: Data) async -> Data {
        let start = CFAbsoluteTimeGetCurrent()
        do {
            let cleaned = try await performSeparation(wavData: wavData)
            let elapsed = CFAbsoluteTimeGetCurrent() - start
            Log.info("[DENOISE] separation done in \(String(format: "%.2f", elapsed))s — \(wavData.count) → \(cleaned.count) bytes")
            return cleaned
        } catch {
            Log.error("[DENOISE] falling back to original audio: \(error)")
            return wavData
        }
    }

    // MARK: - HTTP

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }()

    private static func performSeparation(wavData: Data) async throws -> Data {
        let url = URL(string: "\(ConfigManager.sttMLXAudioURL)/v1/audio/separations")!
        let boundary = UUID().uuidString

        var request = URLRequest(url: url)
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
        append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "GroqTalk.AudioSeparator", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        guard http.statusCode == 200 else {
            let bodyText = String(data: data.prefix(512), encoding: .utf8) ?? "<binary>"
            throw NSError(domain: "GroqTalk.AudioSeparator", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "separations HTTP \(http.statusCode): \(bodyText)"])
        }

        // Primary path: server returns a WAV file directly (Content-Type: audio/wav,
        // or the RIFF/WAVE magic bytes are at the start of the payload).
        if looksLikeWav(data) {
            return data
        }

        // Fallback: server returned JSON with either a base64-encoded WAV or a
        // stems dict. Try to pull a voice/vocals stem out of it.
        if let wav = try extractWavFromJSON(data) {
            return wav
        }

        let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        throw NSError(domain: "GroqTalk.AudioSeparator", code: -2,
                      userInfo: [NSLocalizedDescriptionKey: "unrecognized separations response: \(preview)"])
    }

    // MARK: - Response parsing

    private static func looksLikeWav(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let riff = data.prefix(4)
        let wave = data.subdata(in: 8..<12)
        return riff == Data("RIFF".utf8) && wave == Data("WAVE".utf8)
    }

    /// If the endpoint returns JSON (e.g. `{"vocals": "<base64>"}` or
    /// `{"stems": {"voice": "<base64>"}}`), pull out the first voice-like stem
    /// and base64-decode it.
    private static func extractWavFromJSON(_ data: Data) throws -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }

        let preferredKeys = ["voice", "vocals", "vocal", "speech", "audio", "wav"]

        func decode(_ any: Any?) -> Data? {
            guard let s = any as? String else { return nil }
            // Strip a data-URL prefix if present.
            let cleaned: String
            if let comma = s.firstIndex(of: ","), s.hasPrefix("data:") {
                cleaned = String(s[s.index(after: comma)...])
            } else {
                cleaned = s
            }
            guard let decoded = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters),
                  looksLikeWav(decoded) else { return nil }
            return decoded
        }

        if let dict = obj as? [String: Any] {
            // Top-level voice key
            for k in preferredKeys {
                if let d = decode(dict[k]) { return d }
            }
            // Nested "stems" dict
            if let stems = dict["stems"] as? [String: Any] {
                for k in preferredKeys {
                    if let d = decode(stems[k]) { return d }
                }
            }
        }
        return nil
    }
}
