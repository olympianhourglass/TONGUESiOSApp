import Foundation

struct AnthropicMessage: Codable {
    let role: String
    let content: String
}

struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [AnthropicMessage]
    // Top-level system prompt — Anthropic's request schema keeps it
    // separate from the user/assistant turn list. Nil omits the field
    // entirely so existing call sites continue to send identical bodies.
    let system: String?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages
        case system
    }

    // Custom encode so a nil `system` skips the key entirely instead of
    // emitting `"system": null` — keeps every pre-existing call site
    // wire-identical to before this field was added.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(messages, forKey: .messages)
        if let system, !system.isEmpty {
            try container.encode(system, forKey: .system)
        }
    }
}

struct AnthropicResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }
    let content: [ContentBlock]
}

enum AnthropicError: LocalizedError {
    case http(Int, String)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body):   return "HTTP \(code): \(body)"
        case .decoding(let err):          return "Decoding error: \(err.localizedDescription)"
        }
    }
}
