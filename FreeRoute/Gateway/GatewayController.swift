import Foundation
import Observation

/// 跨线程安全读取的网关参数快照。
/// GatewayServer 的 isLANEnabled / portProvider 是 @Sendable 闭包，
/// 直接读 @MainActor 的 app.settings 会报「main actor-isolated property
/// can not be referenced from a Sendable closure」（Xcode 26.6 实测），
/// 因此把这两个值放进带锁的快照里，由 MainActor 侧同步。
final class GatewayFlags: @unchecked Sendable {
    private let lock = NSLock()
    private var portValue = 3000
    private var lanValue = false

    func update(port: Int, lan: Bool) {
        lock.lock(); portValue = port; lanValue = lan; lock.unlock()
    }

    var port: Int { lock.lock(); defer { lock.unlock() }; return portValue }
    var lan: Bool { lock.lock(); defer { lock.unlock() }; return lanValue }
}

/// 网关控制器：路由分发 + 鉴权 + OpenAI 兼容响应（本机 / 局域网）
@MainActor
@Observable
public final class GatewayController {
    public private(set) var status = GatewayStatus()
    public private(set) var isStarting = false
    public var onLog: ((String) -> Void)?

    private weak var app: AppState?
    private var server: GatewayServer?
    private var ticket = AsyncSemaphore(value: 8)
    private let flags = GatewayFlags()

    public init() {}

    /// 把 MainActor 上的设置同步到跨线程快照
    private func syncFlags() {
        guard let app else { return }
        flags.update(port: app.settings.gatewayPort, lan: app.settings.gatewayLANEnabled)
    }

    func bind(_ app: AppState) {
        self.app = app
        ticket = AsyncSemaphore(value: max(1, app.settings.maxConcurrentRequests))
        syncFlags()
        let s = GatewayServer(
            statusHandler: { [weak self] newStatus in
                Task { @MainActor in
                    guard let self else { return }
                    self.status = newStatus
                    self.app?.monitor.setGatewayRunning(newStatus.isRunning)
                }
            },
            requestHandler: { [weak self] req, ex in
                Task { @MainActor in
                    await self?.dispatch(req, ex)
                }
            },
            isLANEnabled: { [flags] in flags.lan },
            portProvider: { [flags] in flags.port }
        )
        server = s
        status = s.snapshot()
    }

    // MARK: 启停

    public func start() async {
        guard let server, let app else { return }
        isStarting = true
        syncFlags()
        ticket = AsyncSemaphore(value: max(1, app.settings.maxConcurrentRequests))
        server.start()
        try? await Task.sleep(nanoseconds: 400_000_000)
        status = server.snapshot()
        isStarting = false
        app.monitor.setGatewayRunning(status.isRunning)
        onLog?(status.isRunning ? "网关已启动：\(status.loopbackAddress)"
                                : "网关启动失败：\(status.lastError ?? "未知错误")")
    }

    public func stop() {
        server?.stop()
        if let s = server { status = s.snapshot() }
        app?.monitor.setGatewayRunning(false)
        onLog?("网关已停止")
    }

    public func restart() async {
        stop()
        await start()
    }

    public func refreshStatus() {
        syncFlags()   // 用户在设置里改端口/局域网开关后不必重启也能生效
        if let s = server { status = s.snapshot() }
    }

    public var token: String { app?.gatewayToken ?? "" }
    public var maskedToken: String { app?.maskedGatewayToken ?? "" }

    // MARK: 分发

    private func dispatch(_ req: GatewayRequest, _ ex: HTTPExchange) async {
        guard let app else { ex.error("服务未就绪", status: 500); return }

        if req.method == "OPTIONS" {
            ex.raw(Data(), status: 204, contentType: "text/plain")
            return
        }

        // 鉴权：无论本机还是局域网，都要求 Token（不允许未授权访问）
        guard authorize(req, app: app) else {
            ex.error("缺少或错误的 Authorization: Bearer <网关 Token>", status: 401, type: "authentication_error")
            return
        }

        let path = req.path.hasSuffix("/") ? String(req.path.dropLast()) : req.path

        switch (req.method, path) {
        case ("GET", "/"), ("GET", "/health"):
            ex.json([
                "object": "freeroute.gateway",
                "status": "ok",
                "lan_enabled": app.settings.gatewayLANEnabled,
                "endpoints": ["/v1/models", "/v1/chat/completions", "/v1/responses", "/v1/embeddings"]
            ])
        case ("GET", "/v1/models"):
            listModels(app: app, ex: ex)
        case ("POST", "/v1/chat/completions"):
            await chatCompletions(req, app: app, ex: ex)
        case ("POST", "/v1/responses"):
            await responses(req, app: app, ex: ex)
        case ("POST", "/v1/embeddings"):
            await embeddings(req, app: app, ex: ex)
        default:
            ex.error("未知接口 \(req.method) \(req.path)", status: 404, type: "not_found_error")
        }
    }

    private func authorize(_ req: GatewayRequest, app: AppState) -> Bool {
        let expected = app.gatewayToken
        if let h = req.headers["authorization"] {
            let v = h.replacingOccurrences(of: "Bearer ", with: "").trimmingCharacters(in: .whitespaces)
            return v == expected
        }
        if let q = req.query["key"], q == expected { return true }
        return false
    }

    // MARK: GET /v1/models

    private func listModels(app: AppState, ex: HTTPExchange) {
        let now = Int(Date().timeIntervalSince1970)
        let data: [[String: Any]] = app.models.map { m in
            var entry: [String: Any] = [
                "id": m.modelID,
                "object": "model",
                "created": now,
                "owned_by": m.providerName,
                "root": m.modelID,
                "freeroute": [
                    "context_length": m.contextLength as Any,
                    "free": m.isFreeTier,
                    "capabilities": m.capabilities.map { $0.rawValue }
                ] as [String: Any]
            ]
            _ = entry
            return entry
        }
        ex.json(["object": "list", "data": data, "count": data.count])
    }

    // MARK: POST /v1/chat/completions

    private func chatCompletions(_ req: GatewayRequest, app: AppState, ex: HTTPExchange) async {
        let input: ChatIn
        do {
            input = try JSONDecoder.freeroute.decode(ChatIn.self, from: req.body)
        } catch {
            ex.error("请求体解析失败：\(error.localizedDescription)", status: 400)
            return
        }
        let messages = input.messages.map { m -> ChatMessage in
            let role: ChatRole
            switch m.role {
            case "system": role = .system
            case "assistant": role = .assistant
            case "tool": role = .tool
            default: role = .user
            }
            return ChatMessage(role: role, content: m.content?.text ?? "")
        }
        let chat = ChatRequest(
            model: input.model, messages: messages, temperature: input.temperature,
            topP: input.topP, maxTokens: input.maxTokens, stop: input.stop?.values,
            stream: input.stream ?? false,
            responseFormatJSON: input.responseFormat?.jsonString,
            toolsJSON: input.tools?.jsonString, user: input.user
        )
        let pinned = app.models.first { $0.modelID == chat.model }
            ?? app.models.first { $0.modelID.hasSuffix("/" + chat.model) }

        await withTicket {
            if chat.stream {
                ex.beginSSE()
                let id = "chatcmpl-" + GatewayUtil.shortID()
                let created = Int(Date().timeIntervalSince1970)
                do {
                    for try await outcome in app.performStreaming(request: chat, pinned: pinned) {
                        switch outcome {
                        case .delta(let text, let provider, let model, let switched):
                            let chunk: [String: Any] = [
                                "id": id, "object": "chat.completion.chunk", "created": created,
                                "model": model.isEmpty ? chat.model : model,
                                "freeroute": ["provider": provider, "switched": switched],
                                "choices": [["index": 0, "delta": ["content": text], "finish_reason": NSNull()] as [String: Any]]
                            ]
                            if let d = try? JSONSerialization.data(withJSONObject: chunk),
                               let s = String(data: d, encoding: .utf8) { ex.sseLine(s) }
                        case .done(let resp, let notes):
                            let end: [String: Any] = [
                                "id": id, "object": "chat.completion.chunk", "created": created,
                                "model": resp.model,
                                "freeroute": ["provider": resp.providerName, "switched": resp.switched,
                                             "lossy_notes": notes],
                                "choices": [["index": 0, "delta": [:] as [String: Any],
                                             "finish_reason": resp.finishReason ?? "stop"] as [String: Any]],
                                "usage": ["prompt_tokens": resp.usage?.promptTokens ?? 0,
                                          "completion_tokens": resp.usage?.completionTokens ?? 0,
                                          "total_tokens": resp.usage?.totalTokens ?? 0] as [String: Any]
                            ]
                            if let d = try? JSONSerialization.data(withJSONObject: end),
                               let s = String(data: d, encoding: .utf8) { ex.sseLine(s) }
                            ex.sseRaw("data: [DONE]\n\n")
                            ex.finish()
                        case .switching(let from, let to, let reason):
                            let obj: [String: Any] = ["freeroute": ["switching": true, "from": from, "to": to, "reason": reason]]
                            if let d = try? JSONSerialization.data(withJSONObject: obj),
                               let s = String(data: d, encoding: .utf8) { ex.sseLine(s) }
                        }
                    }
                } catch {
                    let status = (error as? UpstreamError)?.status ?? 502
                    let obj: [String: Any] = ["error": ["message": error.localizedDescription,
                                                        "type": status == 429 ? "rate_limit_error" : "upstream_error"]]
                    if let d = try? JSONSerialization.data(withJSONObject: obj),
                       let s = String(data: d, encoding: .utf8) { ex.sseLine(s) }
                    ex.sseRaw("data: [DONE]\n\n")
                    ex.finish()
                }
            } else {
                do {
                    let outcome = try await app.perform(request: chat, pinned: pinned)
                    let r = outcome.response
                    let obj: [String: Any] = [
                        "id": r.id, "object": "chat.completion", "created": Int(Date().timeIntervalSince1970),
                        "model": r.model,
                        "freeroute": ["provider": r.providerName, "switched": r.switched,
                                      "attempts": outcome.attempts, "lossy_notes": outcome.lossyNotes],
                        "choices": [["index": 0,
                                     "message": ["role": "assistant", "content": r.text] as [String: Any],
                                     "finish_reason": r.finishReason ?? "stop"] as [String: Any]],
                        "usage": ["prompt_tokens": r.usage?.promptTokens ?? 0,
                                  "completion_tokens": r.usage?.completionTokens ?? 0,
                                  "total_tokens": r.usage?.totalTokens ?? 0] as [String: Any]
                    ]
                    ex.json(obj)
                } catch {
                    let ue = error as? UpstreamError
                    ex.error(error.localizedDescription, status: ue?.status ?? 502, type: "upstream_error")
                }
            }
        }
    }

    // MARK: POST /v1/responses

    private func responses(_ req: GatewayRequest, app: AppState, ex: HTTPExchange) async {
        let input: ResponsesIn
        do {
            input = try JSONDecoder.freeroute.decode(ResponsesIn.self, from: req.body)
        } catch {
            ex.error("请求体解析失败：\(error.localizedDescription)", status: 400)
            return
        }
        var messages: [ChatMessage] = []
        if let ins = input.instructions { messages.append(ChatMessage(role: .system, content: ins)) }
        for item in input.input.items {
            let role: ChatRole = item.role == "assistant" ? .assistant : .user
            messages.append(ChatMessage(role: role, content: item.content))
        }
        let chat = ChatRequest(model: input.model, messages: messages, temperature: input.temperature,
                               maxTokens: input.maxOutputTokens, stream: false)
        let pinned = app.models.first { $0.modelID == chat.model }

        await withTicket {
            do {
                let outcome = try await app.perform(request: chat, pinned: pinned)
                let r = outcome.response
                let obj: [String: Any] = [
                    "id": "resp-" + GatewayUtil.shortID(),
                    "object": "response",
                    "model": r.model,
                    "status": "completed",
                    "output": [[
                        "type": "message",
                        "role": "assistant",
                        "content": [["type": "output_text", "text": r.text] as [String: Any]]
                    ] as [String: Any]],
                    "usage": ["input_tokens": r.usage?.promptTokens ?? 0,
                              "output_tokens": r.usage?.completionTokens ?? 0,
                              "total_tokens": r.usage?.totalTokens ?? 0] as [String: Any],
                    "freeroute": ["provider": r.providerName, "switched": r.switched,
                                  "attempts": outcome.attempts, "lossy_notes": outcome.lossyNotes]
                ]
                ex.json(obj)
            } catch {
                let ue = error as? UpstreamError
                ex.error(error.localizedDescription, status: ue?.status ?? 502, type: "upstream_error")
            }
        }
    }

    // MARK: POST /v1/embeddings

    private func embeddings(_ req: GatewayRequest, app: AppState, ex: HTTPExchange) async {
        let input: EmbedIn
        do {
            input = try JSONDecoder.freeroute.decode(EmbedIn.self, from: req.body)
        } catch {
            ex.error("请求体解析失败：\(error.localizedDescription)", status: 400)
            return
        }
        let texts: [String] = input.input.items.map { $0.content.isEmpty ? input.input.text : $0.content }
        let target = app.models.first { $0.modelID == input.model }
            ?? app.models.first { $0.modelID.hasSuffix("/" + input.model) }
        guard let model = target else {
            ex.error("找不到模型 \(input.model)。请先在模型中心刷新，或确认该服务商提供 embeddings", status: 404)
            return
        }
        guard let provider = app.providers.first(where: { $0.id == model.providerID }),
              let apiKey = app.key(for: provider) else {
            ex.error("该模型的服务商缺少 API Key", status: 400)
            return
        }
        let adapter = AdapterFactory.adapter(for: provider.protocolType)

        await withTicket {
            do {
                var collected: [[String: Any]] = []
                for (i, t) in texts.enumerated() {
                    let one = EmbeddingsRequest(model: model.modelID, input: [t], dimensions: input.dimensions)
                    let call = try adapter.embeddingsCall(provider: provider, apiKey: apiKey, request: one)
                    let (data, _) = try await UpstreamClient.shared.data(for: call, timeout: provider.timeout)
                    let parsed = try adapter.parseEmbeddings(provider: provider, data: data)
                    for item in parsed.data {
                        collected.append(["object": "embedding", "index": i, "embedding": item.embedding])
                    }
                }
                ex.json(["object": "list", "model": model.modelID, "data": collected,
                         "freeroute": ["provider": provider.name]])
            } catch {
                let ue = error as? UpstreamError
                ex.error(error.localizedDescription, status: ue?.status ?? 502, type: "upstream_error")
            }
        }
    }

    // MARK: 并发闸门

    private func withTicket(_ body: () async -> Void) async {
        await ticket.wait()
        await body()
        await ticket.signal()
    }
}

// MARK: - 网关内部解码结构（兼容 OpenAI 可变字段）

struct ChatIn: Decodable {
    var model: String
    var messages: [Msg]
    var temperature: Double?
    var topP: Double?
    var maxTokens: Int?
    var stop: StopField?
    var stream: Bool?
    var user: String?
    var responseFormat: JSONValue?
    var tools: JSONValue?

    struct Msg: Decodable {
        var role: String
        var content: ContentField?
    }
}

struct ResponsesIn: Decodable {
    var model: String
    var instructions: String?
    var input: InputField
    var temperature: Double?
    var maxOutputTokens: Int?
    var stream: Bool?
}

struct EmbedIn: Decodable {
    var model: String
    var input: InputField
    var dimensions: Int?
}

enum StopField: Decodable {
    case single(String), many([String])
    var values: [String] {
        switch self {
        case .single(let s): return [s]
        case .many(let a): return a
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let a = try? c.decode([String].self) { self = .many(a); return }
        self = .single((try? c.decode(String.self)) ?? "")
    }
}

enum ContentField: Decodable {
    case text(String), parts([[String: JSONValue]])
    var text: String {
        switch self {
        case .text(let t): return t
        case .parts(let parts):
            return parts.compactMap { $0["text"]?.string }.joined(separator: " ")
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .parts(a.compactMap { $0.object }); return }
        self = .text("")
    }
}

enum InputField: Decodable {
    struct Item: Decodable {
        var type: String?
        var role: String?
        var text: String?
        var content: ContentField?
        var asText: String { text ?? content?.text ?? "" }
    }
    case text(String), items([Item])

    var text: String { if case .text(let t) = self { return t }; return "" }
    var items: [GatewayItem] {
        switch self {
        case .text(let t): return [GatewayItem(role: "user", content: t)]
        case .items(let arr): return arr.map { GatewayItem(role: $0.role ?? "user", content: $0.asText) }
        }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .text(s); return }
        if let a = try? c.decode([Item].self) { self = .items(a); return }
        self = .text("")
    }
}

struct GatewayItem: Hashable { let role: String; let content: String }

enum GatewayUtil {
    static func shortID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16).description
    }
}

/// 简易异步信号量（限制网关并发）
public actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(value: Int) { available = max(1, value) }

    public func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { cont in waiters.append(cont) }
    }

    public func signal() {
        if waiters.isEmpty { available += 1; return }
        waiters.removeFirst().resume()
    }
}

extension JSONDecoder {
    static var freeroute: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
}
