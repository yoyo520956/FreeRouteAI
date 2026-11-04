import Foundation

/// OpenAI 兼容协议（Chat Completions + Models + Embeddings + SSE 流式）
/// 适用：OpenRouter / Groq / Cerebras / Cloudflare Workers AI / NVIDIA NIM / Hugging Face / OpenAI 及任意兼容端点
public struct OpenAICompatibleAdapter: ProtocolAdapter {
    public let protocolType: ProviderProtocolType = .openaiCompatible
    public init() {}

    // MARK: 模型目录

    public func modelsCall(provider: Provider, apiKey: String) throws -> UpstreamCall {
        let path = provider.modelsPath ?? "/models"
        let headers = baseHeaders(provider: provider, apiKey: apiKey)
        var base = provider.baseURL
        if base.contains("{account_id}") {
            let account = provider.customHeaders["CF-Account-Id"]
                ?? provider.customHeaders["cf-account-id"] ?? ""
            base = base.replacingOccurrences(of: "{account_id}", with: account)
        }
        return try UpstreamCall(url: URLCompose.join(base, path), method: "GET", headers: headers)
    }

    public func parseModels(provider: Provider, data: Data) throws -> [DiscoveredModel] {
        guard let root = FRJSON.object(data) else {
            throw UpstreamError.decoding("模型列表不是 JSON 对象")
        }
        var items: [JSONValue] = []
        if case .array(let a)? = root["data"] { items = a }
        else if case .array(let a)? = root["models"] { items = a }
        else if case .array(let a)? = root["objects"] { items = a }

        var out: [DiscoveredModel] = []
        for item in items {
            let id: String?
            if case .string(let s)? = item["id"] { id = s }
            else if case .string(let s)? = item["name"] { id = s.replacingOccurrences(of: "models/", with: "") }
            else { id = nil }
            guard let id else { continue }

            var display: String?
            if case .string(let s)? = item["name"] { display = s }
            if case .string(let s)? = item["display_name"] { display = s }

            var ctx: Int?
            if case .number(let n)? = item["context_length"] { ctx = Int(n) }
            if case .number(let n)? = item["context"] { ctx = Int(n) }
            if case .object(let o)? = item["supported_parameters"], case .number(let n)? = o["max_context_length"] { ctx = Int(n) }

            var caps: [ModelCapability] = [.text]
            if let params = item["supported_parameters"]?.array {
                let names = Set(params.compactMap { $0.string })
                if names.contains("tools") || names.contains("tool_choice") { caps.append(.functionCalling) }
                if names.contains("response_format") || names.contains("json_schema") { caps.append(.structuredOutput) }
            }
            if let arch = item["architecture"]?.object, case .array(let mods)? = arch["input_modalities"] {
                let m = Set(mods.compactMap { $0.string })
                if m.contains("image") { caps.append(.vision) }
                if m.contains("audio") { caps.append(.audio) }
                if m.contains("text") && !caps.contains(.text) { caps.append(.text) }
            }
            if case .array(let t)? = item["taskType"], t.contains(where: { $0.string == "embeddings" || $0.string == "sentence-similarity" }) {
                caps.append(.embeddings)
            }
            if id.lowercased().contains("embed") { caps.append(.embeddings) }

            var free = false
            if case .number(let p)? = item["pricing"]?.object?["prompt"], p == 0 { free = true }
            if id.lowercased().contains(":free") || id.lowercased().hasSuffix("-free") { free = true }

            var inPrice: Double?, outPrice: Double?
            if let pr = item["pricing"]?.object {
                inPrice = pr["prompt"]?.number
                outPrice = pr["completion"]?.number
            }

            out.append(DiscoveredModel(
                modelID: id, displayName: display, contextLength: ctx,
                capabilities: Array(Set(caps)), isFreeTier: free,
                inputPricePer1K: inPrice.map { $0 * 1000 },
                outputPricePer1K: outPrice.map { $0 * 1000 },
                note: String((item["description"]?.string ?? "").prefix(200))
            ))
        }
        return out
    }

    // MARK: 对话

    public func chatCall(provider: Provider, apiKey: String, request: ChatRequest) throws -> UpstreamCall {
        let path = provider.requestPath ?? "/chat/completions"
        var headers = baseHeaders(provider: provider, apiKey: apiKey)
        headers["Content-Type"] = "application/json"
        if request.stream { headers["Accept"] = "text/event-stream" }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(request.messages.map { msg in
                var o: [String: JSONValue] = [
                    "role": .string(msg.role.rawValue),
                    "content": .string(msg.content)
                ]
                if let extra = msg.rawExtra?.object {
                    for (k, v) in extra { o[k] = v }
                }
                return .object(o)
            }),
            "stream": .bool(request.stream)
        ]
        if let t = request.temperature { body["temperature"] = .number(t) }
        if let p = request.topP { body["top_p"] = .number(p) }
        if let m = request.maxTokens { body["max_tokens"] = .number(Double(m)) }
        if let s = request.stop, !s.isEmpty { body["stop"] = .array(s.map { JSONValue.string($0) }) }
        if let u = request.user { body["user"] = .string(u) }
        if let rf = request.responseFormatJSON, let v = FRJSON.any(Data(rf.utf8)) { body["response_format"] = v }
        if let tl = request.toolsJSON, let v = FRJSON.any(Data(tl.utf8)) {
            body["tools"] = v
            body["tool_choice"] = .string("auto")
        }
        if request.stream {
            body["stream_options"] = .object(["include_usage": .bool(true)])
        }

        let data = try JSONSerialization.data(withJSONObject: JSONValue.bridgeForSend(body))
        return try UpstreamCall(url: URLCompose.join(provider.baseURL, path), method: "POST", headers: headers, body: data)
    }

    public func parseChat(provider: Provider, data: Data) throws -> ChatResponse {
        guard let root = FRJSON.object(data) else { throw UpstreamError.decoding("响应不是 JSON 对象") }
        let id = root["id"]?.string ?? UUID().uuidString
        let model = root["model"]?.string ?? ""
        var text = ""
        var finish: String?
        if case .array(let choices)? = root["choices"], let first = choices.first {
            if case .string(let c)? = first["text"] { text = c }
            if let msg = first["message"]?.object { text = msg["content"]?.string ?? "" }
            finish = first["finish_reason"]?.string
        }
        var usage: UsageInfo?
        if let u = root["usage"]?.object {
            usage = UsageInfo(
                promptTokens: FRJSON.int(u["prompt_tokens"]) ?? 0,
                completionTokens: FRJSON.int(u["completion_tokens"]) ?? 0,
                totalTokens: FRJSON.int(u["total_tokens"]) ?? 0,
                cachedTokens: FRJSON.int(u["prompt_tokens_details"]?.object?["cached_tokens"]) ?? 0
            )
        }
        return ChatResponse(id: id, model: model, providerName: provider.name, text: text,
                            finishReason: finish, usage: usage)
    }

    public func parseStreamLine(_ line: String, provider: Provider) -> StreamPiece? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("data:") { s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        if s == "[DONE]" { return StreamPiece(isDone: true) }
        guard let root = FRJSON.object(Data(s.utf8)) else { return nil }

        var piece = StreamPiece()
        if case .array(let choices)? = root["choices"], let first = choices.first {
            if let delta = first["delta"]?.object {
                // 部分服务商把推理内容放在 reasoning / reasoning_content
                piece.text = delta["content"]?.string
                    ?? delta["reasoning_content"]?.string
                    ?? delta["reasoning"]?.string
                    ?? ""
            } else if case .string(let t)? = first["text"] {
                piece.text = t
            }
            piece.finish = first["finish_reason"]?.string
        }
        if let u = root["usage"]?.object {
            piece.usage = UsageInfo(
                promptTokens: FRJSON.int(u["prompt_tokens"]) ?? 0,
                completionTokens: FRJSON.int(u["completion_tokens"]) ?? 0,
                totalTokens: FRJSON.int(u["total_tokens"]) ?? 0
            )
        }
        if let err = root["error"]?.object {
            return StreamPiece(text: "", finish: nil, isDone: true)
        }
        if piece.text.isEmpty && piece.usage == nil && piece.finish == nil { return nil }
        return piece
    }

    // MARK: 向量

    public func embeddingsCall(provider: Provider, apiKey: String, request: EmbeddingsRequest) throws -> UpstreamCall {
        guard let path = provider.embeddingsPath else { throw AdapterError.unsupported("未配置 embeddings 路径") }
        var headers = baseHeaders(provider: provider, apiKey: apiKey)
        headers["Content-Type"] = "application/json"
        var body: [String: Any] = ["model": request.model, "input": request.input]
        if let d = request.dimensions { body["dimensions"] = d }
        if let e = request.encodingType { body["encoding_format"] = e }
        let data = try JSONSerialization.data(withJSONObject: body)
        return try UpstreamCall(url: URLCompose.join(provider.baseURL, path), method: "POST", headers: headers, body: data)
    }

    public func parseEmbeddings(provider: Provider, data: Data) throws -> EmbeddingsResponse {
        guard let root = FRJSON.object(data), case .array(let arr)? = root["data"] else {
            throw UpstreamError.decoding("embeddings 响应缺少 data 数组")
        }
        var items: [EmbeddingItem] = []
        for (i, v) in arr.enumerated() {
            var vec: [Double] = []
            if case .array(let nums)? = v["embedding"] { vec = nums.compactMap { $0.number } }
            items.append(EmbeddingItem(object: "embedding", index: FRJSON.int(v["index"]) ?? i, embedding: vec))
        }
        return EmbeddingsResponse(object: "list", model: root["model"]?.string ?? "", data: items, usage: nil)
    }

    public func lossyNotes(for request: ChatRequest) -> [String] {
        var notes: [String] = []
        if request.toolsJSON != nil { notes.append("已按 OpenAI 工具调用格式透传（上游不支持时会被忽略）") }
        if request.responseFormatJSON != nil { notes.append("response_format 已透传（上游不支持时会被忽略）") }
        return notes
    }

    // MARK: 私有

    private func baseHeaders(provider: Provider, apiKey: String) -> [String: String] {
        var h: [String: String] = [:]
        if !apiKey.isEmpty { h["Authorization"] = "Bearer \(apiKey)" }
        if provider.kind == .openrouter {
            h["HTTP-Referer"] = "https://freeroute.local"
            h["X-Title"] = "FreeRoute AI"
        }
        for (k, v) in provider.customHeaders where !k.isEmpty { h[k] = v }
        return h
    }

    private func extractAccount(from provider: Provider) -> String? {
        // 用户在自定义 Header 或 notes 中提供：CF-Account-Id
        if let v = provider.customHeaders["CF-Account-Id"], !v.isEmpty { return v }
        if let v = provider.customHeaders["cf-account-id"], !v.isEmpty { return v }
        return nil
    }
}

extension JSONValue {
    /// 供 JSONSerialization 使用的桥接（内部工具）
    static func bridgeForSend(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let d): return d
        case .string(let s): return s
        case .array(let a): return a.map { bridgeForSend($0) }
        case .object(let o): return o.mapValues { bridgeForSend($0) }
        }
    }
    static func bridgeForSend(_ dict: [String: JSONValue]) -> [String: Any] {
        dict.mapValues { bridgeForSend($0) }
    }
}
