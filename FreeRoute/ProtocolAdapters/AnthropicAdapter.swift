import Foundation

/// Anthropic Messages 协议（含 SSE：message_start / content_block_delta / message_delta / message_stop）
public struct AnthropicAdapter: ProtocolAdapter {
    public let protocolType: ProviderProtocolType = .anthropic
    public init() {}

    public func modelsCall(provider: Provider, apiKey: String) throws -> UpstreamCall {
        let path = provider.modelsPath ?? "/v1/models"
        return try UpstreamCall(url: URLCompose.join(provider.baseURL, path), method: "GET", headers: headers(provider: provider, apiKey: apiKey))
    }

    public func parseModels(provider: Provider, data: Data) throws -> [DiscoveredModel] {
        guard let root = FRJSON.object(data), case .array(let arr)? = root["data"] else {
            throw UpstreamError.decoding("Anthropic 模型列表缺少 data")
        }
        var out: [DiscoveredModel] = []
        for item in arr {
            guard let id = item["id"]?.string else { continue }
            let display = item["display_name"]?.string
            var ctx: Int?
            if let info = item["info"]?.object, case .number(let n)? = info["context_length"] { ctx = Int(n) }
            out.append(DiscoveredModel(
                modelID: id, displayName: display, contextLength: ctx,
                capabilities: [.text, .vision, .functionCalling, .structuredOutput],
                isFreeTier: false,
                note: (item["description"]?.string ?? "").description
            ))
        }
        return out
    }

    public func chatCall(provider: Provider, apiKey: String, request: ChatRequest) throws -> UpstreamCall {
        let path = provider.requestPath ?? "/v1/messages"
        var hdrs = headers(provider: provider, apiKey: apiKey)
        hdrs["Content-Type"] = "application/json"

        // Anthropic 把 system 作为顶层字段
        var systemText = ""
        var messages: [[String: JSONValue]] = []
        for m in request.messages {
            if m.role == .system {
                systemText += systemText.isEmpty ? m.content : "\n" + m.content
                continue
            }
            messages.append([
                "role": .string(m.role == .tool ? "user" : m.role.rawValue),
                "content": .array([.object(["type": .string("text"), "text": .string(m.content)])])
            ])
        }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages.map { JSONValue.object($0) }),
            // Anthropic 必填 max_tokens
            "max_tokens": .number(Double(request.maxTokens ?? 2048)),
            "stream": .bool(request.stream)
        ]
        if !systemText.isEmpty { body["system"] = .string(systemText) }
        if let t = request.temperature { body["temperature"] = .number(t) }
        if let p = request.topP { body["top_p"] = .number(p) }
        if let s = request.stop, !s.isEmpty { body["stop_sequences"] = .array(s.map { JSONValue.string($0) }) }
        if let tl = request.toolsJSON, let v = FRJSON.any(Data(tl.utf8)) { body["tools"] = v }

        let payload = try JSONSerialization.data(withJSONObject: OpenAICompatBridge.bridge(body))
        return try UpstreamCall(url: URLCompose.join(provider.baseURL, path), method: "POST", headers: hdrs, body: payload)
    }

    public func parseChat(provider: Provider, data: Data) throws -> ChatResponse {
        guard let root = FRJSON.object(data) else { throw UpstreamError.decoding("Anthropic 响应不是 JSON 对象") }
        var text = ""
        if case .array(let blocks)? = root["content"] {
            for b in blocks where b["type"]?.string == "text" {
                text += b["text"]?.string ?? ""
            }
        }
        var usage: UsageInfo?
        if let u = root["usage"]?.object {
            let inp = FRJSON.int(u["input_tokens"]) ?? 0
            let outp = FRJSON.int(u["output_tokens"]) ?? 0
            usage = UsageInfo(promptTokens: inp, completionTokens: outp, totalTokens: inp + outp,
                              cachedTokens: FRJSON.int(u["cache_read_input_tokens"]) ?? 0)
        }
        return ChatResponse(id: root["id"]?.string ?? UUID().uuidString,
                            model: root["model"]?.string ?? "",
                            providerName: provider.name, text: text,
                            finishReason: root["stop_reason"]?.string, usage: usage)
    }

    public func parseStreamLine(_ line: String, provider: Provider) -> StreamPiece? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty || s.hasPrefix("event:") { return nil }
        if s.hasPrefix("data:") { s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        guard let root = FRJSON.object(Data(s.utf8)) else { return nil }
        guard let type = root["type"]?.string else { return nil }

        switch type {
        case "content_block_delta":
            let text = root["delta"]?.object?["text"]?.string ?? ""
            return text.isEmpty ? nil : StreamPiece(text: text)
        case "message_delta":
            var piece = StreamPiece()
            piece.finish = root["delta"]?.object?["stop_reason"]?.string
            if let u = root["usage"]?.object {
                piece.usage = UsageInfo(promptTokens: 0,
                                        completionTokens: FRJSON.int(u["output_tokens"]) ?? 0,
                                        totalTokens: 0)
            }
            return (piece.finish == nil && piece.usage == nil) ? nil : piece
        case "message_stop":
            return StreamPiece(isDone: true)
        case "error":
            return StreamPiece(finish: "error", isDone: true)
        default:
            return nil
        }
    }

    public func embeddingsCall(provider: Provider, apiKey: String, request: EmbeddingsRequest) throws -> UpstreamCall {
        throw AdapterError.unsupported("Anthropic Messages 协议不提供 Embeddings 接口")
    }

    public func parseEmbeddings(provider: Provider, data: Data) throws -> EmbeddingsResponse {
        throw AdapterError.unsupported("Anthropic Messages 协议不提供 Embeddings 接口")
    }

    public func lossyNotes(for request: ChatRequest) -> [String] {
        var notes: [String] = []
        if request.messages.contains(where: { $0.role == .system }) {
            notes.append("system 消息已合并为 Anthropic 顶层 system 字段")
        }
        if request.toolsJSON != nil {
            notes.append("tools 已透传为 Anthropic 格式（字段名兼容时有效，不兼容将被忽略）")
        }
        if request.maxTokens == nil {
            notes.append("Anthropic 必填 max_tokens，已默认补为 2048")
        }
        if request.responseFormatJSON != nil {
            notes.append("Anthropic 无 response_format：结构化输出需改用 tool 方案，本次已忽略该参数")
        }
        return notes
    }

    private func headers(provider: Provider, apiKey: String) -> [String: String] {
        var h: [String: String] = ["anthropic-version": "2023-06-01"]
        if !apiKey.isEmpty { h["x-api-key"] = apiKey }
        for (k, v) in provider.customHeaders where !k.isEmpty { h[k] = v }
        return h
    }
}

/// 内部桥接：把 JSONValue 字典交给 JSONSerialization
enum OpenAICompatBridge {
    static func bridge(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { bridge($0) }
        case .object(let o): return o.mapValues { bridge($0) }
        }
    }
    static func bridge(_ dict: [String: JSONValue]) -> [String: Any] {
        dict.mapValues { bridge($0) }
    }
}
