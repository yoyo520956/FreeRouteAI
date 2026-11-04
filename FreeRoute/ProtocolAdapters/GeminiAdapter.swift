import Foundation

/// Google Gemini REST 协议（generateContent / streamGenerateContent?alt=sse，模型目录带 pageToken 分页）
public struct GeminiAdapter: ProtocolAdapter {
    public let protocolType: ProviderProtocolType = .gemini
    public init() {}

    private static let freeHintTokens = ["flash", "lite", "embedding"]

    // MARK: 模型目录

    public func modelsCall(provider: Provider, apiKey: String) throws -> UpstreamCall {
        let path = provider.modelsPath ?? "/v1beta/models"
        let url = try URLCompose.join(provider.baseURL, path)
        var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var items = comps?.queryItems ?? []
        items.append(URLQueryItem(name: "pageSize", value: "200"))
        if !apiKey.isEmpty { items.append(URLQueryItem(name: "key", value: apiKey)) }
        comps?.queryItems = items
        let finalURL = comps?.url ?? url

        var h = headers(provider: provider, apiKey: apiKey)
        h.removeValue(forKey: "x-goog-api-key") // 目录接口用 query key，避免重复鉴权
        return UpstreamCall(url: finalURL, method: "GET", headers: h)
    }

    public func parseModels(provider: Provider, data: Data) throws -> [DiscoveredModel] {
        guard let root = FRJSON.object(data), case .array(let arr)? = root["models"] else {
            throw UpstreamError.decoding("Gemini 模型列表缺少 models 数组")
        }
        var out: [DiscoveredModel] = []
        for item in arr {
            guard let name = item["name"]?.string else { continue }
            let id = name.replacingOccurrences(of: "models/", with: "")
            var caps: [ModelCapability] = [.text]
            if case .array(let methods)? = item["supportedGenerationMethods"] {
                let t = Set(methods.compactMap { $0.string })
                if t.contains("embedContent") || t.contains("summarizeText") { caps.append(.embeddings) }
                if t.contains("generateContent") && !caps.contains(.text) { caps.append(.text) }
            }
            let lower = id.lowercased()
            let isFree = Self.freeHintTokens.contains { lower.contains($0) }
            out.append(DiscoveredModel(
                modelID: id,
                displayName: item["displayName"]?.string,
                contextLength: FRJSON.int(item["inputTokenLimit"]),
                maxOutputTokens: FRJSON.int(item["outputTokenLimit"]),
                capabilities: caps,
                isFreeTier: isFree,
                note: item["description"]?.string ?? ""
            ))
        }
        return out
    }

    /// 分页游标（供 ProvidersService 循环拉取）
    public func nextPageToken(from data: Data) -> String? {
        FRJSON.object(data)?["nextPageToken"]?.string
    }

    // MARK: 对话

    public func chatCall(provider: Provider, apiKey: String, request: ChatRequest) throws -> UpstreamCall {
        var hdrs = headers(provider: provider, apiKey: apiKey)
        hdrs["Content-Type"] = "application/json"

        var systemText: String?
        var contents: [JSONValue] = []
        for m in request.messages {
            if m.role == .system {
                systemText = (systemText ?? "") + (systemText == nil ? "" : "\n") + m.content
                continue
            }
            let role = m.role == .assistant ? "model" : "user"
            contents.append(.object([
                "role": .string(role),
                "parts": .array([.object(["text": .string(m.content)])])
            ]))
        }

        var config: [String: JSONValue] = [:]
        if let t = request.temperature { config["temperature"] = .number(t) }
        if let p = request.topP { config["topP"] = .number(p) }
        if let m = request.maxTokens { config["maxOutputTokens"] = .number(Double(m)) }
        if let s = request.stop, !s.isEmpty {
            config["stopSequences"] = .array(s.prefix(5).map { JSONValue.string($0) })
        }
        if request.responseFormatJSON != nil {
            config["responseMimeType"] = .string("application/json")
        }

        var body: [String: JSONValue] = ["contents": .array(contents)]
        if let s = systemText {
            body["systemInstruction"] = .object(["parts": .array([.object(["text": .string(s)])])])
        }
        if !config.isEmpty { body["generationConfig"] = .object(config) }

        let path = request.stream
            ? "/v1beta/models/\(request.model):streamGenerateContent?alt=sse"
            : "/v1beta/models/\(request.model):generateContent"

        let payload = try JSONSerialization.data(withJSONObject: OpenAICompatBridge.bridge(body))
        return try UpstreamCall(url: URLCompose.join(provider.baseURL, path), method: "POST", headers: hdrs, body: payload)
    }

    public func parseChat(provider: Provider, data: Data) throws -> ChatResponse {
        guard let root = FRJSON.object(data) else { throw UpstreamError.decoding("Gemini 响应不是 JSON 对象") }
        if let err = root["error"]?.object, let msg = err["message"]?.string {
            throw UpstreamError.http(status: FRJSON.int(err["code"]) ?? 400, message: msg)
        }
        var text = ""
        if case .array(let cands)? = root["candidates"], let first = cands.first {
            if case .array(let parts)? = first["content"]?.object?["parts"] {
                for p in parts { text += p["text"]?.string ?? "" }
            }
        }
        var usage: UsageInfo?
        if let u = root["usageMetadata"]?.object {
            let inp = FRJSON.int(u["promptTokenCount"]) ?? 0
            let outp = FRJSON.int(u["candidatesTokenCount"]) ?? 0
            usage = UsageInfo(promptTokens: inp, completionTokens: outp,
                              totalTokens: FRJSON.int(u["totalTokenCount"]) ?? (inp + outp))
        }
        return ChatResponse(id: UUID().uuidString,
                            model: root["modelVersion"]?.string ?? root["model"]?.string ?? "",
                            providerName: provider.name, text: text, usage: usage)
    }

    public func parseStreamLine(_ line: String, provider: Provider) -> StreamPiece? {
        var s = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if s.hasPrefix("data:") { s = String(s.dropFirst(5)).trimmingCharacters(in: .whitespaces) }
        // alt=sse 下发 JSON 对象；个别兼容网关会下发数组包一个对象，两种都接住
        if let arr = FRJSON.array(Data(s.utf8)), let first = arr.first {
            guard case .object(let obj) = first else { return nil }
            return handle(root: obj)
        }
        guard let root = FRJSON.object(Data(s.utf8)) else { return nil }
        return handle(root: root)
    }

    private func handle(root: [String: JSONValue]) -> StreamPiece? {
        var piece = StreamPiece()
        if case .array(let cands)? = root["candidates"], let first = cands.first {
            if case .array(let parts)? = first["content"]?.object?["parts"] {
                for p in parts { piece.text += p["text"]?.string ?? "" }
            }
            if let reason = first["finishReason"]?.string, !reason.isEmpty { piece.finish = reason.lowercased() }
        }
        if let u = root["usageMetadata"]?.object {
            piece.usage = UsageInfo(
                promptTokens: FRJSON.int(u["promptTokenCount"]) ?? 0,
                completionTokens: FRJSON.int(u["candidatesTokenCount"]) ?? 0,
                totalTokens: FRJSON.int(u["totalTokenCount"]) ?? 0
            )
        }
        if piece.text.isEmpty && piece.usage == nil && piece.finish == nil { return nil }
        return piece
    }

    // MARK: 向量

    public func embeddingsCall(provider: Provider, apiKey: String, request: EmbeddingsRequest) throws -> UpstreamCall {
        var hdrs = headers(provider: provider, apiKey: apiKey)
        hdrs["Content-Type"] = "application/json"
        let firstText = request.input.first ?? ""
        let body: [String: JSONValue] = [
            "content": .object(["parts": .array([.object(["text": .string(firstText)])])])
        ]
        let payload = try JSONSerialization.data(withJSONObject: OpenAICompatBridge.bridge(body))
        return try UpstreamCall(url: URLCompose.join(provider.baseURL, "/v1beta/models/\(request.model):embedContent"),
                                method: "POST", headers: hdrs, body: payload)
    }

    public func parseEmbeddings(provider: Provider, data: Data) throws -> EmbeddingsResponse {
        guard let root = FRJSON.object(data),
              case .array(let vals)? = root["embedding"]?.object?["values"],
              !vals.isEmpty else {
            throw UpstreamError.decoding("Gemini embedContent 响应缺少 embedding.values")
        }
        let vec = vals.compactMap { $0.number }
        return EmbeddingsResponse(
            object: "list",
            model: root["model"]?.string ?? provider.name,
            data: [EmbeddingItem(object: "embedding", index: 0, embedding: vec)],
            usage: nil
        )
    }

    // MARK: 有损转换说明

    public func lossyNotes(for request: ChatRequest) -> [String] {
        var notes: [String] = []
        if request.messages.filter({ $0.role == .system }).count > 1 {
            notes.append("Gemini 仅支持单一 systemInstruction，多条 system 已合并")
        }
        if request.toolsJSON != nil {
            notes.append("Gemini 需要 functionDeclarations 专属 schema，OpenAI tools 未自动转换（本次已忽略该参数）")
        }
        if request.responseFormatJSON != nil {
            notes.append("response_format 已近似为 responseMimeType=application/json")
        }
        if (request.stop?.count ?? 0) > 5 {
            notes.append("stop 序列已按 Gemini 上限截断为 5 条")
        }
        return notes
    }

    private func headers(provider: Provider, apiKey: String) -> [String: String] {
        var h: [String: String] = [:]
        if !apiKey.isEmpty { h["x-goog-api-key"] = apiKey }
        for (k, v) in provider.customHeaders where !k.isEmpty { h[k] = v }
        return h
    }
}
