import Foundation

// MARK: - 上游 HTTP 请求描述

public struct UpstreamCall: Sendable {
    public var url: URL
    public var method: String
    public var headers: [String: String]
    public var body: Data?

    public init(url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }

    public func urlRequest(timeout: TimeInterval) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        return req
    }
}

public enum AdapterError: LocalizedError, Sendable {
    case badBaseURL(String)
    case missingPath(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .badBaseURL(let s):  return "Base URL 无效：\(s)"
        case .missingPath(let s): return "缺少路径配置：\(s)"
        case .unsupported(let s): return "该服务商不支持：\(s)"
        }
    }
}

/// 流式解析结果（一行流式数据 → 统一片段）
public struct StreamPiece: Sendable {
    public var text: String
    public var usage: UsageInfo?
    public var finish: String?
    public var isDone: Bool

    public init(text: String = "", usage: UsageInfo? = nil, finish: String? = nil, isDone: Bool = false) {
        self.text = text; self.usage = usage; self.finish = finish; self.isDone = isDone
    }
}

/// 协议适配器：把统一 ChatRequest 翻译成各家上游请求，并把响应翻译回统一事件
public protocol ProtocolAdapter: Sendable {
    var protocolType: ProviderProtocolType { get }

    func modelsCall(provider: Provider, apiKey: String) throws -> UpstreamCall
    func parseModels(provider: Provider, data: Data) throws -> [DiscoveredModel]

    func chatCall(provider: Provider, apiKey: String, request: ChatRequest) throws -> UpstreamCall
    func parseChat(provider: Provider, data: Data) throws -> ChatResponse
    func parseStreamLine(_ line: String, provider: Provider) -> StreamPiece?

    func embeddingsCall(provider: Provider, apiKey: String, request: EmbeddingsRequest) throws -> UpstreamCall
    func parseEmbeddings(provider: Provider, data: Data) throws -> EmbeddingsResponse

    /// 转换过程中被丢弃或近似的字段（不得静默丢弃）
    func lossyNotes(for request: ChatRequest) -> [String]
}

public enum AdapterFactory {
    public static func adapter(for type: ProviderProtocolType) -> ProtocolAdapter {
        switch type {
        case .openaiCompatible: return OpenAICompatibleAdapter()
        case .gemini:           return GeminiAdapter()
        case .anthropic:        return AnthropicAdapter()
        case .ollama:           return OllamaAdapter()
        }
    }
}

// MARK: - URL 组合工具

enum URLCompose {
    static func join(_ base: String, _ path: String) throws -> URL {
        var b = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        var p = path
        if !p.hasPrefix("/") { p = "/" + p }
        // 用户常把 baseURL 填成含版本段的 https://host/v1beta，而适配器路径自带
        // /v1beta/...，拼出 /v1beta/v1beta/... 会直接 404。版本段重复时丢掉适配器那份。
        if let last = b.split(separator: "/").last, isVersionSegment(String(last)),
           p.hasPrefix("/" + last + "/") {
            p = String(p.dropFirst(("/" + last).count))
        }
        let s = b + p
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "{}")
        let escaped = s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        // 必须带 http/https：URL(string:) 对「不是网址」这类输入也会成功（当成相对 URL），
        // 不校验 scheme 就会把一个根本没有主机的 URL 发出去，错误信息还很难懂。
        guard let url = URL(string: escaped),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { throw AdapterError.badBaseURL(s) }
        return url
    }

    /// 判断是否 /v1、/v1beta、/v2alpha 这类版本路径段
    private static func isVersionSegment(_ seg: String) -> Bool {
        guard seg.hasPrefix("v"), seg.count >= 2 else { return false }
        let rest = Array(seg.dropFirst())
        var i = 0
        while i < rest.count, rest[i].isNumber { i += 1 }
        guard i > 0 else { return false }
        return rest[i...].allSatisfy { $0.isLetter }
    }
}

/// 统一 JSON 编解码器（上游字段多为 snake_case，统一处理）
enum FRJSON {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
    /// 宽松 JSON 解析（用于各家差异大的响应）
    static func any(_ data: Data) -> JSONValue? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue.from(any: obj)
    }
    static func object(_ data: Data) -> [String: JSONValue]? {
        if case .object(let o) = FRJSON.any(data) { return o }
        return nil
    }
    static func array(_ data: Data) -> [JSONValue]? {
        if case .array(let a) = FRJSON.any(data) { return a }
        return nil
    }
    static func text(_ v: JSONValue?) -> String? { v?.string }
    static func int(_ v: JSONValue?) -> Int? { v?.number.map { Int($0) } }
    static func dbl(_ v: JSONValue?) -> Double? { v?.number }
}
