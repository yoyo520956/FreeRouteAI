import Foundation

/// Ollama 原生协议（/api/chat 流式为 NDJSON 逐行 JSON；/api/tags 为模型列表）
public struct OllamaAdapter: ProtocolAdapter {
    public let protocolType: ProviderProtocolType = .ollama
    public init() {}

    // MARK: 模型目录

    public func modelsCall(provider: Provider, apiKey: String) throws -> UpstreamCall {
        let path = provider.modelsPath ?? "/api/tags"
        return try UpstreamCall(url: URLCompose.join(provider.baseURL, path), method: "GET", headers: headers(provider: provider, apiKey: apiKey))
    }

    public func parseModels(provider: Provider, data: Data) throws -> [DiscoveredModel] {
        guard let root = FRJSON.object(data), case .array(let arr)? = root["models"] else {
            throw UpstreamError.decoding("Ollama /api/tags 缺少 models 数组")
        }
        var out: [DiscoveredModel] = []
        for item in arr {
            guard let name = item["name"]?.string ?? item["model"]?.string else { continue }
            var ctx: Int?
            if let details = item["details"]?.object {
                if let f = FRJSON.dbl(details["num_ctx"]) { ctx = Int(f) }
            }
            out.append(DiscoveredModel(
                modelID: name,
                displayName: name,
                contextLength: ctx,
                capabilities: [.text],
                isFreeTier: true,
                note: item["details"]?.object?["family"]?.string ?? "本地模型（不消耗额度）"
            ))
        }
        return out
    }

    // MARK: 对话

    public func chatCall(provider: Provider, apiKey: String, request: ChatRequest) throws -> UpstreamCall {
        var hdrs = headers(provider: provider, apiKey: apiKey)
        hdrs["Content-Type"] = "application/json"

        let messages: [JSONValue] = request.messages.map { m in
            .object([
                "role": .string(m.role.rawValue),
                "content": .string(m.content)
            ])
        }
        var options: [String: JSONValue] = [:]
        if let t = request.temperature { options["temperature"] = .number(t) }
        if let p = request.topP { options["top_p"] = .number(p) }
        if let s = request.stop, !s.isEmpty { options["stop"] = .array(s.map { JSONValue.string($0) }) }
        if request.responseFormatJSON != nil { options["format"] = .string("json") }

        var body: [String: JSONValue] = [
            "model": .string(request.model),
            "messages": .array(messages),
            "stream": .bool(request.stream)
        ]
        if !options.isEmpty { body["options"] = .object(options) }

        let payload = try JSONSerialization.data(withJSONObject: OpenAICompatBridge.bridge(body))
        let path = provider.requestPath ?? "/api/chat"
        return try UpstreamCall(url: URLCompose.join(provider.baseURL, path), method: "POST", headers: hdrs, body: payload)
    }

    public func parseChat(provider: Provider, data: Data) throws -> ChatResponse {
        guard let root = FRJSON.object(data) else { throw UpstreamError.decoding("Ollama 响应不是 JSON 对象") }
        if let err = root["error"]?.string { throw UpstreamError.http(status: 400, message: err) }
        let text = root["message"]?.object?["content"]?.string ?? root["response"]?.string ?? ""
        let inp = FRJSON.int(root["prompt_eval_count"]) ?? 0
        let outp = FRJSON.int(root["eval_count"]) ?? 0
        let usage = (inp + outp) > 0
            ? UsageInfo(promptTokens: inp, completionTokens: outp, totalTokens: inp + outp)
            : nil
        return ChatResponse(id: root["created_at"]?.string ?? UUID().uuidString,
                            model: root["model"]?.string ?? "",
                            providerName: provider.name,
                            text: text,
                            finishReason: root["done"]?.bool == true ? "stop" : nil,
                            usage: usage)
    }

    /// Ollama 流式是 NDJSON（每行一个完整 JSON），不是 SSE
    public func parseStreamLine(_ line: String, provider: Provider) -> StreamPiece? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("data:") { s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        guard let root = FRJSON.object(Data(s.utf8)) else { return nil }

        var piece = StreamPiece()
        piece.text = root["message"]?.object?["content"]?.string ?? root["response"]?.string ?? ""
        let done = root["done"]?.bool ?? false
        let inp = FRJSON.int(root["prompt_eval_count"]) ?? 0
        let outp = FRJSON.int(root["eval_count"]) ?? 0
        if inp + outp > 0 {
            piece.usage = UsageInfo(promptTokens: inp, completionTokens: outp, totalTokens: inp + outp)
        }
        if done { piece.finish = "stop"; piece.isDone = true }
        if piece.text.isEmpty && piece.usage == nil && !piece.isDone { return nil }
        return piece
    }

    // MARK: 向量

    public func embeddingsCall(provider: Provider, apiKey: String, request: EmbeddingsRequest) throws -> UpstreamCall {
        var hdrs = headers(provider: provider, apiKey: apiKey)
        hdrs["Content-Type"] = "application/json"
        let body: [String: JSONValue] = [
            "model": .string(request.model),
            "input": .array(request.input.map { JSONValue.string($0) })
        ]
        let payload = try JSONSerialization.data(withJSONObject: OpenAICompatBridge.bridge(body))
        return try UpstreamCall(url: URLCompose.join(provider.baseURL, "/api/embed"), method: "POST", headers: hdrs, body: payload)
    }

    public func parseEmbeddings(provider: Provider, data: Data) throws -> EmbeddingsResponse {
        guard let root = FRJSON.object(data), case .array(let arr)? = root["embeddings"] else {
            throw UpstreamError.decoding("Ollama /api/embed 缺少 embeddings 数组")
        }
        var items: [EmbeddingItem] = []
        for (i, v) in arr.enumerated() {
            var vec: [Double] = []
            if case .array(let nums) = v { vec = nums.compactMap { $0.number } }
            items.append(EmbeddingItem(object: "embedding", index: i, embedding: vec))
        }
        return EmbeddingsResponse(object: "list", model: provider.name, data: items, usage: nil)
    }

    public func lossyNotes(for request: ChatRequest) -> [String] {
        var notes: [String] = []
        if request.toolsJSON != nil { notes.append("Ollama /api/chat 的 tools 需模型支持，未支持时将被忽略") }
        if request.responseFormatJSON != nil { notes.append("response_format 已近似为 format=json") }
        if request.maxTokens != nil { notes.append("Ollama 使用 num_predict 控制长度，max_tokens 未直接映射") }
        return notes
    }

    private func headers(provider: Provider, apiKey: String) -> [String: String] {
        var h: [String: String] = [:]
        if !apiKey.isEmpty { h["Authorization"] = "Bearer \(apiKey)" }
        for (k, v) in provider.customHeaders where !k.isEmpty { h[k] = v }
        return h
    }
}
