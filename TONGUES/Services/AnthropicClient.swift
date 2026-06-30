import Foundation

enum AnthropicClient {
    // URLRequest's default timeout is 60s — long generations (full
    // curriculum plans, large decks) regularly exceed that because no
    // bytes arrive until the model finishes the whole response. 5
    // minutes comfortably covers the worst case without masking real
    // connectivity failures forever.
    private static let requestTimeout: TimeInterval = 300

    private static let apiKey = Secrets.anthropicAPIKey

    static func sendMessage(
        _ messages: [AnthropicMessage],
        system: String? = nil,
        model: String = "claude-opus-4-7",
        maxTokens: Int = 16000
    ) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = AnthropicRequest(
            model: model,
            maxTokens: maxTokens,
            messages: messages,
            system: system
        )
        let encoder = JSONEncoder()
        // The `system` key is optional in Anthropic's schema; without
        // this strategy we'd encode `"system": null` on every legacy
        // call, which their server rejects on some endpoints.
        encoder.outputFormatting = []
        request.httpBody = try encoder.encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicError.http(0, "No HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.http(httpResponse.statusCode, bodyText)
        }
        do {
            let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            return decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        } catch {
            throw AnthropicError.decoding(error)
        }
    }

    // Tool-use variant: content-block messages + tool definitions in,
    // full response (text blocks and/or tool_use blocks) out. Used by
    // TutorAgent's agent loop — the caller owns the execute-tools /
    // append-results / re-send cycle; this function is one wire
    // round-trip. Plain-text call sites keep using sendMessage above;
    // nothing about their behavior changes.
    static func sendToolMessage(
        _ messages: [AnthropicToolMessage],
        system: String? = nil,
        tools: [AnthropicTool]? = nil,
        toolChoice: AnthropicToolChoice? = nil,
        model: String = "claude-sonnet-4-6",
        maxTokens: Int = 4096
    ) async throws -> AnthropicToolResponse {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        let body = AnthropicToolRequest(
            model: model,
            maxTokens: maxTokens,
            messages: messages,
            system: system,
            tools: tools,
            toolChoice: toolChoice
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicError.http(0, "No HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.http(httpResponse.statusCode, bodyText)
        }
        do {
            return try JSONDecoder().decode(AnthropicToolResponse.self, from: data)
        } catch {
            throw AnthropicError.decoding(error)
        }
    }

    // Structured-output helpers. Every call site in the app that wants
    // typed data back from Claude goes through one of these instead of
    // the plain-text sendMessage path — the wire shape is forced
    // tool-use, so the response is schema-validated JSON rather than a
    // prose blob we have to coax JSON out of.

    static func sendStructured<T: Decodable>(
        toolName: String,
        toolDescription: String,
        schema: JSONValue,
        userPrompt: String,
        system: String? = nil,
        model: String = "claude-opus-4-7",
        maxTokens: Int = 16000,
        as _: T.Type = T.self
    ) async throws -> T {
        try await sendStructured(
            toolName: toolName,
            toolDescription: toolDescription,
            schema: schema,
            messages: [.user(userPrompt)],
            system: system,
            model: model,
            maxTokens: maxTokens,
            as: T.self
        )
    }

    static func sendStructured<T: Decodable>(
        toolName: String,
        toolDescription: String,
        schema: JSONValue,
        messages: [AnthropicToolMessage],
        system: String? = nil,
        model: String = "claude-opus-4-7",
        maxTokens: Int = 16000,
        as _: T.Type = T.self
    ) async throws -> T {
        try await sendStructuredOutput(
            toolName: toolName,
            toolDescription: toolDescription,
            schema: schema,
            messages: messages,
            system: system,
            model: model,
            maxTokens: maxTokens,
            as: T.self
        ).decoded
    }

    // Same as `sendStructured` but also exposes the raw JSON string the
    // model submitted to the tool. Callers that want to persist the
    // model's output verbatim (e.g. DeckGenerator's `rawJSON` debug
    // field) use this variant; everyone else uses `sendStructured`.
    static func sendStructuredOutput<T: Decodable>(
        toolName: String,
        toolDescription: String,
        schema: JSONValue,
        messages: [AnthropicToolMessage],
        system: String? = nil,
        model: String = "claude-opus-4-7",
        maxTokens: Int = 16000,
        as _: T.Type = T.self
    ) async throws -> (decoded: T, rawJSON: String) {
        let tool = AnthropicTool(
            name: toolName,
            description: toolDescription,
            inputSchema: schema
        )
        let response = try await sendToolMessage(
            messages,
            system: system,
            tools: [tool],
            toolChoice: .tool(name: toolName),
            model: model,
            maxTokens: maxTokens
        )
        guard let block = response.toolUses.first,
              let json = block.input?.jsonString,
              let data = json.data(using: .utf8) else {
            throw NSError(
                domain: "AnthropicClient",
                code: 100,
                userInfo: [NSLocalizedDescriptionKey: "Expected a tool_use call to \(toolName) but Claude didn't make one (stop_reason: \(response.stopReason ?? "nil")). Any text content: \(response.joinedText.isEmpty ? "<empty>" : response.joinedText)"]
            )
        }
        do {
            let decoded = try JSONDecoder().decode(T.self, from: data)
            return (decoded, json)
        } catch let DecodingError.keyNotFound(key, ctx) {
            throw structuredDecodingError(
                toolName: toolName,
                reason: "missing required key '\(key.stringValue)' at \(decodingPath(ctx))",
                rawJSON: json
            )
        } catch let DecodingError.valueNotFound(_, ctx) {
            throw structuredDecodingError(
                toolName: toolName,
                reason: "null value where non-null expected at \(decodingPath(ctx))",
                rawJSON: json
            )
        } catch let DecodingError.typeMismatch(type, ctx) {
            throw structuredDecodingError(
                toolName: toolName,
                reason: "wrong type at \(decodingPath(ctx)) — expected \(type)",
                rawJSON: json
            )
        } catch let DecodingError.dataCorrupted(ctx) {
            throw structuredDecodingError(
                toolName: toolName,
                reason: "corrupted data at \(decodingPath(ctx)): \(ctx.debugDescription)",
                rawJSON: json
            )
        } catch {
            throw structuredDecodingError(
                toolName: toolName,
                reason: error.localizedDescription,
                rawJSON: json
            )
        }
    }

    private static func decodingPath(_ ctx: DecodingError.Context) -> String {
        let parts = ctx.codingPath.map { $0.stringValue.isEmpty ? "[\($0.intValue ?? 0)]" : $0.stringValue }
        return parts.isEmpty ? "<root>" : parts.joined(separator: ".")
    }

    private static func structuredDecodingError(
        toolName: String,
        reason: String,
        rawJSON: String
    ) -> NSError {
        NSError(
            domain: "AnthropicClient",
            code: 101,
            userInfo: [NSLocalizedDescriptionKey: """
                Claude's tool_use payload for `\(toolName)` didn't match the expected shape: \(reason).

                Raw payload Claude submitted:
                \(rawJSON)
                """]
        )
    }

    // Vision-aware structured output. Single user turn with an image
    // block + a text prompt + a forced tool call. Used by the camera
    // identify-object flow and anything else that needs schema-validated
    // typed data back from a multimodal call.
    static func sendStructuredVision<T: Decodable>(
        toolName: String,
        toolDescription: String,
        schema: JSONValue,
        imageBase64: String,
        mediaType: String = "image/jpeg",
        userPrompt: String,
        system: String? = nil,
        model: String = "claude-haiku-4-5-20251001",
        maxTokens: Int = 1024,
        as _: T.Type = T.self
    ) async throws -> T {
        try await sendStructured(
            toolName: toolName,
            toolDescription: toolDescription,
            schema: schema,
            messages: [
                .userWithImage(base64: imageBase64, mediaType: mediaType, text: userPrompt)
            ],
            system: system,
            model: model,
            maxTokens: maxTokens,
            as: T.self
        )
    }

    // Multimodal variant: one image content block followed by a text
    // prompt. Used by the camera object-identification flow. Defaults to
    // Haiku 4.5 because vision identification is a high-volume,
    // latency-sensitive call where Opus-class quality isn't needed.
    static func sendVisionMessage(
        imageBase64: String,
        mediaType: String = "image/jpeg",
        prompt: String,
        model: String = "claude-haiku-4-5-20251001",
        maxTokens: Int = 1024
    ) async throws -> String {
        struct ImageSource: Encodable {
            let type: String
            let mediaType: String
            let data: String
            enum CodingKeys: String, CodingKey {
                case type
                case mediaType = "media_type"
                case data
            }
        }
        struct VisionBlock: Encodable {
            let type: String
            let source: ImageSource?
            let text: String?
        }
        struct VisionMessage: Encodable {
            let role: String
            let content: [VisionBlock]
        }
        struct VisionRequest: Encodable {
            let model: String
            let maxTokens: Int
            let messages: [VisionMessage]
            enum CodingKeys: String, CodingKey {
                case model
                case maxTokens = "max_tokens"
                case messages
            }
        }

        let body = VisionRequest(
            model: model,
            maxTokens: maxTokens,
            messages: [
                VisionMessage(role: "user", content: [
                    VisionBlock(
                        type: "image",
                        source: ImageSource(type: "base64", mediaType: mediaType, data: imageBase64),
                        text: nil
                    ),
                    VisionBlock(
                        type: "text",
                        source: nil,
                        text: prompt
                    )
                ])
            ]
        )

        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AnthropicError.http(0, "No HTTP response")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw AnthropicError.http(httpResponse.statusCode, bodyText)
        }
        do {
            let decoded = try JSONDecoder().decode(AnthropicResponse.self, from: data)
            return decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        } catch {
            throw AnthropicError.decoding(error)
        }
    }
}
