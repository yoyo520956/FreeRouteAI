import Foundation

// MARK: - 无损 JSON 值（用于透传无法直接建模的上游字段，禁止静默丢弃）

public enum JSONValue: Codable, Hashable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw UpstreamError.decoding("无法解析 JSON 值")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var number: Double? {
        switch self {
        case .number(let v): return v
        case .bool(let v): return v ? 1 : 0
        default: return nil
        }
    }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    public var jsonString: String {
        let data = try? JSONSerialization.data(withJSONObject: Self.bridge(self), options: [.fragmentsAllowed])
        if let data, let s = String(data: data, encoding: .utf8) { return s }
        return "null"
    }
    private static func bridge(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { bridge($0) }
        case .object(let o): return o.mapValues { bridge($0) }
        }
    }
    public static func from(any: Any) -> JSONValue {
        if let v = any as? JSONValue { return v }
        if let s = any as? String { return .string(s) }
        if let b = any as? Bool { return .bool(b) }
        if let d = any as? Double { return .number(d) }
        if let i = any as? Int { return .number(Double(i)) }
        if let a = any as? [Any] { return .array(a.map { from(any: $0) }) }
        if let o = any as? [String: Any] { return .object(o.mapValues { from(any: $0) }) }
        return .null
    }
}

// MARK: - 聊天消息

public enum ChatRole: String, Codable, Sendable {
    case system, user, assistant, tool
}

public struct ChatMessage: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var role: ChatRole
    public var content: String
    /// 无损透传：上游 function calling 原始 JSON（如 OpenAI 的 tool_calls）
    public var rawExtra: JSONValue?

    public init(id: UUID = UUID(), role: ChatRole, content: String, rawExtra: JSONValue? = nil) {
        self.id = id; self.role = role; self.content = content; self.rawExtra = rawExtra
    }
}

public struct UsageInfo: Codable, Hashable, Sendable {
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var cachedTokens: Int

    public init(promptTokens: Int = 0, completionTokens: Int = 0, totalTokens: Int = 0, cachedTokens: Int = 0) {
        self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.totalTokens = totalTokens; self.cachedTokens = cachedTokens
    }
}

// MARK: - 请求 / 响应（网关统一模型）

public struct ChatRequest: Codable, Sendable {
    public var model: String
    public var messages: [ChatMessage]
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    public var stop: [String]?
    public var stream: Bool
    public var responseFormatJSON: String?   // 结构化输出透传
    public var toolsJSON: String?            // function calling 透传
    public var user: String?

    public init(model: String, messages: [ChatMessage], temperature: Double? = nil, topP: Double? = nil,
                maxTokens: Int? = nil, stop: [String]? = nil, stream: Bool = false,
                responseFormatJSON: String? = nil, toolsJSON: String? = nil, user: String? = nil) {
        self.model = model; self.messages = messages; self.temperature = temperature; self.topP = topP
        self.maxTokens = maxTokens; self.stop = stop; self.stream = stream
        self.responseFormatJSON = responseFormatJSON; self.toolsJSON = toolsJSON; self.user = user
    }
}

public struct ChatResponse: Codable, Sendable {
    public var id: String
    public var model: String
    public var providerName: String
    public var text: String
    public var finishReason: String?
    public var usage: UsageInfo?
    public var latencyMs: Double
    public var switched: Bool     // 是否发生了故障切换

    public init(id: String, model: String, providerName: String, text: String,
                finishReason: String? = nil, usage: UsageInfo? = nil, latencyMs: Double = 0, switched: Bool = false) {
        self.id = id; self.model = model; self.providerName = providerName; self.text = text
        self.finishReason = finishReason; self.usage = usage; self.latencyMs = latencyMs; self.switched = switched
    }
}

/// 流式事件（上游 → 网关/监控统一事件）
public enum CompletionEvent: Sendable {
    case started(provider: String, model: String)
    case delta(String)
    case usage(UsageInfo)
    case done(finish: String?)
    case upstreamError(String)
}

// MARK: - OpenAI Responses API（/v1/responses）

public struct ResponsesInput: Codable, Sendable {
    public var text: String
    public var items: [ResponsesItem]?
}

public struct ResponsesItem: Codable, Hashable, Sendable {
    public var type: String
    public var role: String?
    public var content: String?
    public var raw: JSONValue?
}

public struct ResponsesRequest: Codable, Sendable {
    public var model: String
    public var instructions: String?
    public var input: ResponsesInput
    public var temperature: Double?
    public var maxOutputTokens: Int?
    public var stream: Bool
    public var extraJSON: [String: JSONValue]?
}

public struct ResponsesOutputItem: Codable, Hashable, Sendable {
    public var type: String
    public var role: String
    public var content: String
}

public struct ResponsesResponse: Codable, Sendable {
    public var id: String
    public var object: String
    public var model: String
    public var output: [ResponsesOutputItem]
    public var usage: UsageInfo?
}

// MARK: - Embeddings

public struct EmbeddingsRequest: Codable, Sendable {
    public var model: String
    public var input: [String]
    public var dimensions: Int?
    public var encodingType: String?

    public init(model: String, input: [String], dimensions: Int? = nil, encodingType: String? = nil) {
        self.model = model; self.input = input; self.dimensions = dimensions; self.encodingType = encodingType
    }
}

public struct EmbeddingItem: Codable, Sendable {
    public var object: String
    public var index: Int
    public var embedding: [Double]
}

public struct EmbeddingsResponse: Codable, Sendable {
    public var object: String
    public var model: String
    public var data: [EmbeddingItem]
    public var usage: UsageInfo?
}
