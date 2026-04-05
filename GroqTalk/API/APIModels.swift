import Foundation

struct ModelsResponse: Decodable {
    let data: [ModelEntry]?
    struct ModelEntry: Decodable { let id: String }
}

struct ChatRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
}

struct ChatMessage: Codable {
    let role: String
    let content: String
}

struct ChatResponse: Decodable {
    let choices: [ChatChoice]
    let usage: ChatUsage?
}

struct ChatChoice: Decodable {
    let message: ChatMessage
}

struct ChatUsage: Decodable {
    let totalTokens: Int
    enum CodingKeys: String, CodingKey { case totalTokens = "total_tokens" }
}
