import Foundation

// MARK: - Tool-use wire types
//
// The original AnthropicMessage/AnthropicRequest pair (AnthropicAPI.swift)
// only speaks plain-text turns — every existing one-shot call keeps using
// it unchanged. These types add the tool-use subset of the Messages API:
// content-block messages, tool definitions, and tool_use / tool_result
// blocks. Used exclusively by `AnthropicClient.sendToolMessage` and the
// TutorAgent loop.

// Any-JSON value. Tool input schemas and tool_use inputs are free-form
// JSON, so we need a Codable representation that round-trips arbitrary
// structures without defining a struct per tool.
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? container.decode(Double.self) {
            self = .number(n)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let n): try container.encode(n)
        case .bool(let b):   try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a):  try container.encode(a)
        case .null:          try container.encodeNil()
        }
    }

    // MARK: Convenience accessors (tool-input plumbing)

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var numberValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var intValue: Int? {
        numberValue.map { Int($0) }
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    subscript(key: String) -> JSONValue? {
        objectValue?[key]
    }

    /// Serializes this value to a compact JSON string. Used when a tool
    /// input sub-object (e.g. a whole curriculum plan) needs to be handed
    /// to a JSONDecoder for typed decoding.
    var jsonString: String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// One tool the model may call. `inputSchema` is a standard JSON Schema
// object expressed as JSONValue so each tool definition stays a literal
// in Swift source.
struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONValue

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
    }
}

// MARK: - JSON Schema builders
//
// Tiny convenience layer over JSONValue so structured-output schemas
// read like Swift instead of nested .object/.string/.array case noise.
// Every field is positional + named so the caller's intent is obvious
// at the call site.
extension JSONValue {
    static func schemaObject(
        properties: [String: JSONValue],
        required: [String] = [],
        description: String? = nil
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            fields["required"] = .array(required.map { .string($0) })
        }
        if let description {
            fields["description"] = .string(description)
        }
        return .object(fields)
    }

    static func schemaString(_ description: String) -> JSONValue {
        .object([
            "type": .string("string"),
            "description": .string(description)
        ])
    }

    static func schemaNullableString(_ description: String) -> JSONValue {
        .object([
            "type": .array([.string("string"), .string("null")]),
            "description": .string(description)
        ])
    }

    static func schemaInt(_ description: String) -> JSONValue {
        .object([
            "type": .string("integer"),
            "description": .string(description)
        ])
    }

    static func schemaNumber(_ description: String) -> JSONValue {
        .object([
            "type": .string("number"),
            "description": .string(description)
        ])
    }

    static func schemaBool(_ description: String) -> JSONValue {
        .object([
            "type": .string("boolean"),
            "description": .string(description)
        ])
    }

    static func schemaArray(items: JSONValue, description: String? = nil) -> JSONValue {
        var fields: [String: JSONValue] = [
            "type": .string("array"),
            "items": items
        ]
        if let description {
            fields["description"] = .string(description)
        }
        return .object(fields)
    }

    static func schemaEnum(
        _ values: [String],
        description: String? = nil,
        allowNull: Bool = false
    ) -> JSONValue {
        var fields: [String: JSONValue] = [
            "enum": .array(values.map { .string($0) })
        ]
        if allowNull {
            fields["type"] = .array([.string("string"), .string("null")])
        } else {
            fields["type"] = .string("string")
        }
        if let description {
            fields["description"] = .string(description)
        }
        return .object(fields)
    }
}

// Image payload for vision-capable content blocks. Anthropic's wire
// schema is `{"type":"base64","media_type":"image/jpeg","data":"..."}`.
struct AnthropicImageSource: Codable {
    let type: String        // "base64"
    let mediaType: String   // e.g. "image/jpeg"
    let data: String        // base64-encoded image bytes

    enum CodingKeys: String, CodingKey {
        case type
        case mediaType = "media_type"
        case data
    }
}

// One content block inside a tool-capable message. Exactly one of the
// payload field-sets is populated depending on `type`:
//   "text"        → text
//   "image"       → source                     (multimodal user turns)
//   "tool_use"    → id + name + input          (assistant turns)
//   "tool_result" → toolUseId + content        (user turns we send back)
struct AnthropicToolContentBlock: Codable {
    let type: String
    var text: String?
    var source: AnthropicImageSource?
    var id: String?
    var name: String?
    var input: JSONValue?
    var toolUseId: String?
    var content: String?
    var isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, text, source, id, name, input, content
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }

    static func text(_ text: String) -> AnthropicToolContentBlock {
        AnthropicToolContentBlock(type: "text", text: text)
    }

    static func image(base64: String, mediaType: String = "image/jpeg") -> AnthropicToolContentBlock {
        AnthropicToolContentBlock(
            type: "image",
            source: AnthropicImageSource(type: "base64", mediaType: mediaType, data: base64)
        )
    }

    static func toolResult(
        toolUseId: String,
        content: String,
        isError: Bool = false
    ) -> AnthropicToolContentBlock {
        AnthropicToolContentBlock(
            type: "tool_result",
            toolUseId: toolUseId,
            content: content,
            isError: isError ? true : nil
        )
    }
}

// A message whose content is a list of blocks rather than a flat string.
struct AnthropicToolMessage: Codable {
    let role: String
    let content: [AnthropicToolContentBlock]

    static func user(_ text: String) -> AnthropicToolMessage {
        AnthropicToolMessage(role: "user", content: [.text(text)])
    }

    static func assistant(_ text: String) -> AnthropicToolMessage {
        AnthropicToolMessage(role: "assistant", content: [.text(text)])
    }

    static func userWithImage(
        base64: String,
        mediaType: String = "image/jpeg",
        text: String
    ) -> AnthropicToolMessage {
        AnthropicToolMessage(
            role: "user",
            content: [.image(base64: base64, mediaType: mediaType), .text(text)]
        )
    }
}

// Wire encoding of Anthropic's `tool_choice` field. We model only the
// two shapes we use: `.auto` (model may or may not call a tool — used
// by TutorAgent's agentic loop) and `.tool(name:)` (the model MUST
// call this specific tool — used by every structured-output call so
// the response is guaranteed schema-validated JSON).
enum AnthropicToolChoice: Encodable {
    case auto
    case tool(name: String)

    enum CodingKeys: String, CodingKey { case type, name }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .auto:
            try container.encode("auto", forKey: .type)
        case .tool(let name):
            try container.encode("tool", forKey: .type)
            try container.encode(name, forKey: .name)
        }
    }
}

struct AnthropicToolRequest: Encodable {
    let model: String
    let maxTokens: Int
    let messages: [AnthropicToolMessage]
    let system: String?
    let tools: [AnthropicTool]?
    let toolChoice: AnthropicToolChoice?

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case messages, system, tools
        case toolChoice = "tool_choice"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(model, forKey: .model)
        try container.encode(maxTokens, forKey: .maxTokens)
        try container.encode(messages, forKey: .messages)
        if let system, !system.isEmpty {
            try container.encode(system, forKey: .system)
        }
        if let tools, !tools.isEmpty {
            try container.encode(tools, forKey: .tools)
        }
        if let toolChoice {
            try container.encode(toolChoice, forKey: .toolChoice)
        }
    }
}

struct AnthropicToolResponse: Decodable {
    let content: [AnthropicToolContentBlock]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }

    /// Concatenation of every text block — the model's prose answer.
    var joinedText: String {
        content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }

    /// Every tool invocation the model requested this turn.
    var toolUses: [AnthropicToolContentBlock] {
        content.filter { $0.type == "tool_use" }
    }

    var wantsToolUse: Bool { stopReason == "tool_use" }

    /// Reconstructs this response as the assistant message to append to
    /// the running transcript before sending tool results back.
    var asAssistantMessage: AnthropicToolMessage {
        AnthropicToolMessage(role: "assistant", content: content)
    }
}
