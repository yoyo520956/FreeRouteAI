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
                "endpoints": [
                    "/v1/models", "/v1/chat/completions", "/v1/completions",
                    "/v1/responses", "/v1/embeddings", "/v1/tools",
                    "/v1/agent/tasks", "/v1/agent/tasks/{id}", "/v1/agent/tasks/{id}/events",
                    "/v1/agent/tools", "/v1/agent/models", "/v1/agent/status",
                    "/v1/devices", "/v1/devices/{id}/approve",
                    "/v1/gateway/status", "/v1/prompts"
                ]
            ])
        case ("GET", "/v1/models"):
            listModels(app: app, ex: ex)
        case ("POST", "/v1/chat/completions"):
            // Agent 模式检测：Header X-FreeRoute-Agent: 1 或 body.freeroute.agent=true
            let isAgent = req.headers["x-freeroute-agent"] == "1"
                || (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any])?
                    .flatMap { $0["freeroute"] as? [String: Any] }?
                    .flatMap { $0["agent"] as? Bool } == true
            if isAgent {
                await agentChatCompletions(req, app: app, ex: ex)
            } else {
                await chatCompletions(req, app: app, ex: ex)
            }
        case ("POST", "/v1/completions"):
            await completions(req, app: app, ex: ex)
        case ("POST", "/v1/responses"):
            await responses(req, app: app, ex: ex)
        case ("POST", "/v1/embeddings"):
            await embeddings(req, app: app, ex: ex)
        case ("GET", "/v1/tools"):
            listTools(app: app, ex: ex)
        case ("POST", "/v1/agent/chat/completions"):
            await agentChatCompletions(req, app: app, ex: ex)
        case ("POST", "/v1/agent/tasks"):
            await createAgentTask(req, app: app, ex: ex)
        case ("GET", _):
            if path.hasPrefix("/v1/agent/tasks/") {
                let parts = path.dropFirst("/v1/agent/tasks/".count).split(separator: "/")
                if parts.count == 1 {
                    await getAgentTask(String(parts[0]), app: app, ex: ex)
                } else if parts.count == 2, parts[1] == "events" {
                    await agentTaskEvents(String(parts[0]), app: app, ex: ex)
                } else {
                    ex.error("未知接口 \(req.method) \(req.path)", status: 404, type: "not_found_error")
                }
            } else if path == "/v1/agent/tools" {
                listAgentTools(app: app, ex: ex)
            } else if path == "/v1/agent/models" {
                listAgentModels(app: app, ex: ex)
            } else if path == "/v1/agent/status" {
                agentStatus(app: app, ex: ex)
            } else if path == "/v1/devices" {
                listDevices(app: app, ex: ex)
            } else if path == "/v1/gateway/status" {
                gatewayStatus(app: app, ex: ex)
            } else if path == "/v1/prompts" {
                listPrompts(ex: ex)
            } else if path.hasPrefix("/v1/prompts/") {
                let pid = String(path.dropFirst("/v1/prompts/".count))
                getPrompt(pid, ex: ex)
            } else {
                ex.error("未知接口 \(req.method) \(req.path)", status: 404, type: "not_found_error")
            }
        case ("POST", _):
            if path.hasPrefix("/v1/devices/"), path.hasSuffix("/approve") {
                let devId = String(path.dropFirst("/v1/devices/".count).dropLast("/approve".count))
                await approveDevice(devId, req, app: app, ex: ex)
            } else if path.hasPrefix("/v1/agent/tasks/"), path.hasSuffix("/cancel") {
                let taskId = String(path.dropFirst("/v1/agent/tasks/".count).dropLast("/cancel".count))
                await cancelAgentTask(taskId, app: app, ex: ex)
            } else if path == "/v1/prompts" {
                upsertPrompt(req, ex: ex)
            } else {
                ex.error("未知接口 \(req.method) \(req.path)", status: 404, type: "not_found_error")
            }
        case ("DELETE", _):
            if path.hasPrefix("/v1/prompts/") {
                let pid = String(path.dropFirst("/v1/prompts/".count))
                deletePrompt(pid, ex: ex)
            } else {
                ex.error("未知接口 \(req.method) \(req.path)", status: 404, type: "not_found_error")
            }
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

    // MARK: POST /v1/completions (OpenAI 兼容单轮补全)

    private func completions(_ req: GatewayRequest, app: AppState, ex: HTTPExchange) async {
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
            toolsJSON: nil, user: input.user
        )
        let pinned = app.models.first { $0.modelID == chat.model }
            ?? app.models.first { $0.modelID.hasSuffix("/" + chat.model) }

        await withTicket {
            if chat.stream {
                ex.beginSSE()
                let id = "cmpl-" + GatewayUtil.shortID()
                let created = Int(Date().timeIntervalSince1970)
                do {
                    for try await outcome in app.performStreaming(request: chat, pinned: pinned) {
                        switch outcome {
                        case .delta(let text, let provider, let model, let switched):
                            let chunk: [String: Any] = [
                                "id": id, "object": "text_completion", "created": created,
                                "model": model.isEmpty ? chat.model : model,
                                "freeroute": ["provider": provider, "switched": switched],
                                "choices": [["index": 0, "text": text, "finish_reason": NSNull()] as [String: Any]]
                            ]
                            if let d = try? JSONSerialization.data(withJSONObject: chunk),
                               let s = String(data: d, encoding: .utf8) { ex.sseLine(s) }
                        case .done(let resp, let notes):
                            let end: [String: Any] = [
                                "id": id, "object": "text_completion", "created": created,
                                "model": resp.model,
                                "freeroute": ["provider": resp.providerName, "switched": resp.switched,
                                             "lossy_notes": notes],
                                "choices": [["index": 0, "text": resp.text, "finish_reason": resp.finishReason ?? "stop"] as [String: Any]],
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
                        "id": "cmpl-" + GatewayUtil.shortID(),
                        "object": "text_completion", "created": Int(Date().timeIntervalSince1970),
                        "model": r.model,
                        "freeroute": ["provider": r.providerName, "switched": r.switched,
                                      "attempts": outcome.attempts, "lossy_notes": outcome.lossyNotes],
                        "choices": [["index": 0, "text": r.text, "finish_reason": r.finishReason ?? "stop"] as [String: Any]],
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

    // MARK: POST /v1/chat/completions (Agent 模式) & POST /v1/agent/chat/completions

    private func agentChatCompletions(_ req: GatewayRequest, app: AppState, ex: HTTPExchange) async {
        let input: AgentIn
        do {
            input = try JSONDecoder.freeroute.decode(AgentIn.self, from: req.body)
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

        // 构建 ToolContext（真实执行上下文）
        let ctx = AgentContextFactory.makeContext(from: app)

        // prompt 引用解析：按名从 PromptStore 取内容，与 systemPrompt 合并
        var resolvedSystem = input.systemPrompt ?? ""
        if let pname = input.prompt, !pname.isEmpty {
            if let saved = PromptStore().find(name: pname) {
                resolvedSystem = resolvedSystem.isEmpty ? saved.content : saved.content + "\n\n" + resolvedSystem
            } else {
                ex.error("找不到 prompt「\(pname)」。可先 GET /v1/prompts 查看已保存列表，或用 POST /v1/prompts 创建", status: 404, type: "not_found_error")
                return
            }
        }

        let config = AgentRunConfig(
            goal: input.goal ?? "用户请求",
            model: input.model,
            messages: messages,
            protocolType: .openaiCompatible, // 网关内部统一用 OpenAI 兼容格式；上游适配器会转
            ctx: ctx,
            maxSteps: input.maxSteps ?? 20,
            maxResultChars: input.maxResultChars ?? 8000,
            toolTimeout: input.toolTimeout ?? 30,
            includeTools: input.includeTools ?? true,
            systemPrompt: resolvedSystem.isEmpty ? nil : resolvedSystem,
            stream: input.stream ?? false,
            pinned: AgentModelResolver.resolve(input.model, in: app).providerID.flatMap { pid in
                app.models.first { $0.providerID == pid && $0.modelID == AgentModelResolver.resolve(input.model, in: app).modelID }
            }
        )

        let runner = AgentRunner()
        if config.stream {
            ex.beginSSE()
            let id = "agent-" + GatewayUtil.shortID()
            let created = Int(Date().timeIntervalSince1970)
            var finalText = ""
            var stepsSent = 0

            let result = await runner.run(config: config, upstream: app) { ev in
                if ev.kind == .toolCall || ev.kind == .toolResult {
                    // 流式下发工具调用/结果
                    let chunk: [String: Any] = [
                        "id": id, "object": "agent.event", "created": created,
                        "model": config.model, "freeroute": ["event": ev.asJSONObject]
                    ]
                    if let d = try? JSONSerialization.data(withJSONObject: chunk),
                       let s = String(data: d, encoding: .utf8) { ex.sseLine(s) }
                }
            }
            finalText = result.finalAnswer

            // 最终答案
            let end: [String: Any] = [
                "id": id, "object": "agent.completion", "created": created,
                "model": config.model,
                "freeroute": ["provider": result.providerName, "status": result.status.rawValue,
                             "steps": result.steps.count, "tool_calls": result.toolCallCount],
                "choices": [["index": 0, "message": ["role": "assistant", "content": finalText] as [String: Any],
                             "finish_reason": "stop"] as [String: Any]],
                "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0] as [String: Any]
            ]
            if let d = try? JSONSerialization.data(withJSONObject: end),
               let s = String(data: d, encoding: .utf8) { ex.sseLine(s) }
            ex.sseRaw("data: [DONE]\n\n")
            ex.finish()
        } else {
            let result = await runner.run(config: config, upstream: app) { _ in }
            let obj: [String: Any] = [
                "id": "agent-" + GatewayUtil.shortID(),
                "object": "agent.completion", "created": Int(Date().timeIntervalSince1970),
                "model": config.model,
                "freeroute": ["provider": result.providerName, "status": result.status.rawValue,
                             "steps": result.steps.count, "tool_calls": result.toolCallCount,
                             "duration_ms": result.durationMs],
                "choices": [["index": 0,
                             "message": ["role": "assistant", "content": result.finalAnswer] as [String: Any],
                             "finish_reason": "stop"] as [String: Any]],
                "usage": ["prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0] as [String: Any]
            ]
            ex.json(obj)
        }
    }

    // MARK: POST /v1/agent/tasks

    private func createAgentTask(_ req: GatewayRequest, app: AppState, ex: HTTPExchange) async {
        let input: AgentIn
        do {
            input = try JSONDecoder.freeroute.decode(AgentIn.self, from: req.body)
        } catch {
            ex.error("请求体解析失败：\(error.localizedDescription)", status: 400)
            return
        }
        let taskId = "task_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let ctx = AgentContextFactory.makeContext(from: app)
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
        // prompt 引用解析（与 chat completions 同一份 PromptStore）
        var resolvedSystem = input.systemPrompt ?? ""
        if let pname = input.prompt, !pname.isEmpty {
            if let saved = PromptStore().find(name: pname) {
                resolvedSystem = resolvedSystem.isEmpty ? saved.content : saved.content + "\n\n" + resolvedSystem
            } else {
                ex.error("找不到 prompt「\(pname)」。先 GET /v1/prompts 查看已保存列表", status: 404, type: "not_found_error")
                return
            }
        }
        let config = AgentRunConfig(
            taskId: taskId, goal: input.goal ?? "用户请求",
            model: input.model, messages: messages, protocolType: .openaiCompatible,
            ctx: ctx, maxSteps: input.maxSteps ?? 20, maxResultChars: input.maxResultChars ?? 8000,
            toolTimeout: input.toolTimeout ?? 30, includeTools: input.includeTools ?? true,
            systemPrompt: resolvedSystem.isEmpty ? nil : resolvedSystem,
            stream: input.stream ?? false,
            pinned: AgentModelResolver.resolve(input.model, in: app).providerID.flatMap { pid in
                app.models.first { $0.providerID == pid && $0.modelID == AgentModelResolver.resolve(input.model, in: app).modelID }
            },
            cancellation: nil
        )
        // 存入内存（生产环境可用 SQLite/Redis 持久化）
        agentTasks[taskId] = AgentTaskHandle(config: config, runner: AgentRunner(), upstream: app)
        ex.json(["task_id": taskId, "status": "running", "created_at": Int(Date().timeIntervalSince1970)])
    }

    // 简单内存存储（演示用；生产需持久化）
    private var agentTasks: [String: AgentTaskHandle] = [:]

    private class AgentTaskHandle: @unchecked Sendable {
        let config: AgentRunConfig
        let runner: AgentRunner
        let upstream: AppState
        var result: AgentRunResult?
        var events: [AgentEvent] = []
        var isCancelled = false

        init(config: AgentRunConfig, runner: AgentRunner, upstream: AppState) {
            self.config = config; self.runner = runner; self.upstream = upstream
        }
    }

    // MARK: GET /v1/agent/tasks/{id}

    private func getAgentTask(_ id: String, app: AppState, ex: HTTPExchange) {
        guard let handle = agentTasks[id] else {
            ex.error("任务不存在", status: 404)
            return
        }
        if let r = handle.result {
            ex.json(r.reportJSON)
        } else {
            ex.json(["task_id": id, "status": handle.isCancelled ? "cancelled" : "running",
                     "events": handle.events.map { $0.asJSONObject }])
        }
    }

    // MARK: GET /v1/agent/tasks/{id}/events (SSE)

    private func agentTaskEvents(_ id: String, app: AppState, ex: HTTPExchange) async {
        guard let handle = agentTasks[id] else {
            ex.error("任务不存在", status: 404)
            return
        }
        ex.beginSSE()
        // 先发已有事件
        for ev in handle.events {
            if let d = try? JSONSerialization.data(withJSONObject: ev.asJSONObject),
               let s = String(data: d, encoding: .utf8) { ex.sseLine(s) }
        }
        if handle.result != nil || handle.isCancelled {
            ex.sseRaw("data: [DONE]\n\n")
            ex.finish()
            return
        }
        // 后台跑任务，实时推事件
        await withTicket {
            let result = await handle.runner.run(config: handle.config, upstream: handle.upstream) { ev in
                handle.events.append(ev)
                if let d = try? JSONSerialization.data(withJSONObject: ev.asJSONObject),
                   let s = String(data: d, encoding: .utf8) { ex.sseLine(s) }
            }
            handle.result = result
            ex.sseRaw("data: [DONE]\n\n")
            ex.finish()
        }
    }

    // MARK: POST /v1/agent/tasks/{id}/cancel

    private func cancelAgentTask(_ id: String, app: AppState, ex: HTTPExchange) {
        guard let handle = agentTasks[id] else {
            ex.error("任务不存在", status: 404)
            return
        }
        handle.isCancelled = true
        // 给 Runner 的 cancellation 信号（简化：仅标记，实际需在 run 循环检查）
        ex.json(["task_id": id, "status": "cancelling"])
    }

    // MARK: GET /v1/tools

    private func listTools(app: AppState, ex: HTTPExchange) {
        let tools = ToolCatalog.all.map { spec in
            ["name": spec.name, "title": spec.title, "group": spec.group,
             "summary": spec.summary, "permission": spec.permission.rawValue,
             "requires_confirmation": spec.requiresConfirmation,
             "timeout": spec.timeout, "parameters": spec.parameters.jsonString] as [String: Any]
        }
        ex.json(["object": "list", "data": tools, "count": tools.count])
    }

    // MARK: GET /v1/agent/tools

    private func listAgentTools(app: AppState, ex: HTTPExchange) {
        // 仅返回 Agent 常用的工具（过滤掉需要确认的写入类）
        let tools = ToolCatalog.all.filter { !$0.requiresConfirmation }.map { spec in
            ["name": spec.name, "title": spec.title, "group": spec.group,
             "summary": spec.summary, "permission": spec.permission.rawValue,
             "timeout": spec.timeout, "parameters": spec.parameters.jsonString] as [String: Any]
        }
        ex.json(["object": "list", "data": tools, "count": tools.count])
    }

    // MARK: GET /v1/agent/models

    private func listAgentModels(app: AppState, ex: HTTPExchange) {
        let models = app.models.filter { $0.capabilities.contains(.functionCalling) }
            .map { m -> [String: Any] in
                ["id": m.modelID, "object": "model", "created": Int(Date().timeIntervalSince1970),
                 "owned_by": m.providerName, "freeroute": [
                    "context_length": m.contextLength as Any,
                    "free": m.isFreeTier,
                    "capabilities": m.capabilities.map { $0.rawValue }
                 ]] as [String: Any]
            }
        ex.json(["object": "list", "data": models, "count": models.count])
    }

    // MARK: GET /v1/agent/status

    private func agentStatus(app: AppState, ex: HTTPExchange) {
        let gw = app.gateway.status
        let perms = ToolPermissionStore().enabledPermissions
        let devs = ToolPermissionStore().devices().filter { $0.approved }
        ex.json([
            "gateway": gw,
            "permissions": perms.map { $0.rawValue },
            "approved_devices": devs.count,
            "agent_tasks_running": agentTasks.values.filter { $0.result == nil && !$0.isCancelled }.count,
            "tool_catalog": ToolCatalog.all.count
        ])
    }

    // MARK: GET /v1/devices

    private func listDevices(app: AppState, ex: HTTPExchange) {
        let devs = ToolPermissionStore().devices().map { d -> [String: Any] in
            ["id": d.id, "label": d.label, "remote_address": d.remoteAddress,
             "approved": d.approved, "first_seen": AgentTime.iso(d.firstSeen),
             "last_seen": AgentTime.iso(d.lastSeen)] as [String: Any]
        }
        ex.json(["object": "list", "data": devs, "count": devs.count])
    }

    // MARK: POST /v1/devices/{id}/approve

    private func approveDevice(_ id: String, _ req: GatewayRequest, app: AppState, ex: HTTPExchange) async {
        struct Body: Decodable { var approved: Bool }
        do {
            let body = try JSONDecoder.freeroute.decode(Body.self, from: req.body)
            ToolPermissionStore().approveDevice(id, approved: body.approved)
            ex.json(["id": id, "approved": body.approved])
        } catch {
            ex.error("请求体解析失败：\(error.localizedDescription)", status: 400)
        }
    }

    // MARK: GET /v1/gateway/status

    private func gatewayStatus(app: AppState, ex: HTTPExchange) {
        ex.json(app.gateway.status)
    }

    // MARK: GET /v1/prompts

    private func listPrompts(ex: HTTPExchange) {
        let list = PromptStore().all()
        ex.json(["object": "list", "data": list.map { $0.asJSONObject }, "count": list.count])
    }

    // MARK: GET /v1/prompts/{id}

    private func getPrompt(_ id: String, ex: HTTPExchange) {
        guard let p = PromptStore().all().first(where: { $0.id == id }) else {
            ex.error("找不到 prompt：\(id)", status: 404, type: "not_found_error")
            return
        }
        ex.json(p.asJSONObject)
    }

    // MARK: POST /v1/prompts

    private func upsertPrompt(_ req: GatewayRequest, ex: HTTPExchange) {
        struct Body: Decodable {
            var name: String
            var content: String
            var tags: [String]?
        }
        do {
            let body = try JSONDecoder.freeroute.decode(Body.self, from: req.body)
            guard !body.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  !body.content.trimmingCharacters(in: .whitespaces).isEmpty else {
                ex.error("name 与 content 不能为空", status: 400)
                return
            }
            let saved = PromptStore().upsert(name: body.name, content: body.content, tags: body.tags ?? [])
            ex.json(saved.asJSONObject)
        } catch {
            ex.error("请求体解析失败：\(error.localizedDescription)", status: 400)
        }
    }

    // MARK: DELETE /v1/prompts/{id}

    private func deletePrompt(_ id: String, ex: HTTPExchange) {
        if PromptStore().delete(id: id) {
            ex.json(["id": id, "deleted": true])
        } else {
            ex.error("找不到 prompt：\(id)", status: 404, type: "not_found_error")
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

struct AgentIn: Decodable {
    var model: String
    var messages: [Msg]
    var goal: String?                    // 人类可读的任务目标（可选，用于报告）
    var maxSteps: Int?                   // 最大步数，默认 20
    var maxResultChars: Int?             // 单步结果截断
    var toolTimeout: Double?             // 工具超时秒数
    var includeTools: Bool?              // 是否透传 tools，默认 true
    var systemPrompt: String?            // 额外注入的 system 提示
    var prompt: String?                  // 引用已保存 prompt 的名称（PromptStore）
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
