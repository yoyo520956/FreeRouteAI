import Foundation
import Observation
import SwiftData

/// 全局状态中枢：数据、服务商、模型、路由、网关、监控的唯一入口
@MainActor
@Observable
public final class AppState {
    public static let shared = AppState()

    // MARK: 数据
    public var settings = AppSettings()
    public var providers: [Provider] = []
    public var models: [ModelInfo] = []
    public var recentLogs: [DBRequestLog] = []
    public var isBootstrapping = true
    public var lastError: String?
    /// 云端截图模式：非 nil 时自动切换到对应界面（1...10）
    public var screenshotTarget: Int?

    // MARK: 服务
    public let store: ModelStore
    public let keychain = KeychainStore()
    public let router: RouterEngine
    public let monitor = MonitorFeed()
    public let gateway = GatewayController()
    public let statistics = StatisticsEngine()
    private let upstream = UpstreamClient.shared

    private init() {
        let schema = Schema([DBProvider.self, DBModel.self, DBRequestLog.self])
        let cfg = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [cfg])
            store = ModelStore(container: container)
        } catch {
            // 数据库不可用时退回内存存储，保证 App 不崩
            let mem = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            let container = try! ModelContainer(for: schema, configurations: [mem])
            store = ModelStore(container: container)
        }
        router = RouterEngine(mode: SettingsStore.load().defaultRouterMode)
    }

    // MARK: - 启动

    public func bootstrap() async {
        settings = SettingsStore.load()
        router.mode = settings.defaultRouterMode
        reloadFromStore()
        if providers.isEmpty { seedBuiltins() }
        do { try store.pruneLogs(olderThan: max(1, settings.logRetentionDays)) } catch {}
        recentLogs = (try? store.fetchLogs(limit: 200)) ?? []
        gateway.bind(self)
        monitor.setGatewayRunning(gateway.status.isRunning)
        if settings.autoStartGateway { await gateway.start() }
        isBootstrapping = false
    }

    private func reloadFromStore() {
        providers = (try? store.fetchProviders()) ?? []
        models = (try? store.fetchModels()) ?? []
    }

    /// 首次启动：写入内置服务商模板（不含任何密钥）
    private func seedBuiltins() {
        for p in ProviderCatalog.builtins {
            try? store.saveProvider(p)
        }
        try? store.context.save()
        reloadFromStore()
    }

    public func saveSettings() {
        SettingsStore.save(settings)
        router.mode = settings.defaultRouterMode
    }

    // MARK: - 服务商 CRUD

    public func addProvider(_ p: Provider) {
        try? store.saveProvider(p)
        try? store.context.save()
        reloadFromStore()
    }

    public func updateProvider(_ p: Provider) {
        try? store.saveProvider(p)
        try? store.context.save()
        reloadFromStore()
    }

    public func deleteProvider(_ p: Provider) {
        for k in p.keys { keychain.delete(k.keychainRef) }
        try? store.deleteProvider(id: p.id)
        try? store.context.save()
        reloadFromStore()
    }

    public func setEnabled(_ enabled: Bool, provider p: Provider) {
        var x = p; x.enabled = enabled
        updateProvider(x)
    }

    // MARK: - 密钥（只进 Keychain）

    @discardableResult
    public func setKey(_ value: String, provider p: Provider, label: String = "默认密钥") -> Bool {
        var x = p
        let ref = "provider/\(p.id.uuidString)/default"
        let ok = keychain.set(value, for: ref)
        if let idx = x.keys.firstIndex(where: { $0.keychainRef == ref }) {
            x.keys[idx].status = value.isEmpty ? .unknown : .unknown
            x.keys[idx].lastError = nil
            x.keys[idx].label = label
        } else {
            x.keys.append(APIKeyRef(label: label, keychainRef: ref))
        }
        updateProvider(x)
        return ok
    }

    public func deleteKey(provider p: Provider) {
        for k in p.keys { keychain.delete(k.keychainRef) }
        var x = p
        x.keys = []
        updateProvider(x)
    }

    public func key(for p: Provider) -> String? {
        guard let ref = p.keys.first?.keychainRef else { return nil }
        return keychain.get(ref)
    }

    public func maskedKey(for p: Provider) -> String {
        guard let v = key(for: p), !v.isEmpty else { return "未设置" }
        return KeychainStore.mask(v)
    }

    public func updateKeyStatus(providerID: UUID, status: KeyStatus, error: String? = nil) {
        guard var p = providers.first(where: { $0.id == providerID }) else { return }
        guard !p.keys.isEmpty else { return }
        p.keys[0].status = status
        p.keys[0].lastError = error
        p.keys[0].lastUsed = Date()
        try? store.saveProvider(p)
        try? store.context.save()
        if let i = providers.firstIndex(where: { $0.id == providerID }) { providers[i] = p }
    }

    // MARK: - 模型

    public func models(of p: Provider) -> [ModelInfo] {
        models.filter { $0.providerID == p.id }
    }

    public func model(id: String) -> ModelInfo? {
        models.first { $0.id == id || $0.modelID == id }
    }

    public func updateModelHealth(_ m: ModelInfo, health: ModelHealth, successRate: Double? = nil, latency: Double? = nil) {
        guard let idx = models.firstIndex(where: { $0.id == m.id }) else { return }
        models[idx].health = health
        if let s = successRate { models[idx].successRate = s }
        if let l = latency {
            let old = models[idx].avgLatencyMs ?? l
            models[idx].avgLatencyMs = old * 0.7 + l * 0.3
        }
        if let row = try? store.context.fetch(FetchDescriptor<DBModel>()).first(where: { $0.id == m.id }) {
            row.healthRaw = health.rawValue
            if let s = successRate { row.successRate = s }
            if let l = models[idx].avgLatencyMs { row.avgLatencyMs = l }
        }
    }

    // MARK: - 模型发现（真实请求上游目录，禁止伪造）

    public struct RefreshReport: Sendable {
        public var providerName: String
        public var added: Int
        public var total: Int
        public var error: String?
        public init(providerName: String, added: Int, total: Int, error: String? = nil) {
            self.providerName = providerName; self.added = added; self.total = total; self.error = error
        }
    }

    public func refreshModels(provider p: Provider) async -> RefreshReport {
        guard let apiKey = key(for: p), !apiKey.isEmpty else {
            return RefreshReport(providerName: p.name, added: 0, total: 0, error: "尚未设置 API Key")
        }
        let adapter = AdapterFactory.adapter(for: p.protocolType)
        guard p.supportsModelDiscovery else {
            return RefreshReport(providerName: p.name, added: 0, total: 0,
                                 error: "该服务商未提供模型目录接口（不支持动态发现），请手动添加模型")
        }
        do {
            var collected: [DiscoveredModel] = []
            var seen = Set<String>()
            var call = try adapter.modelsCall(provider: p, apiKey: apiKey)
            for _ in 0..<10 {  // 分页上限 10 页，防死循环
                let (data, _) = try await upstream.data(for: call, timeout: p.timeout)
                let page = try adapter.parseModels(provider: p, data: data)
                for m in page where !seen.contains(m.modelID) {
                    seen.insert(m.modelID)
                    collected.append(m)
                }
                guard let g = adapter as? GeminiAdapter, let token = g.nextPageToken(from: data), !token.isEmpty else { break }
                var comps = URLComponents(url: call.url, resolvingAgainstBaseURL: false)
                var items = comps?.queryItems ?? []
                items.append(URLQueryItem(name: "pageToken", value: token))
                comps?.queryItems = items
                guard let u = comps?.url else { break }
                call = UpstreamCall(url: u, method: "GET", headers: call.headers)
            }
            let infos = collected.map { d -> ModelInfo in
                ModelInfo(providerID: p.id, providerName: p.name, modelID: d.modelID,
                          displayName: d.displayName ?? d.modelID,
                          capabilities: d.capabilities.isEmpty ? [.text] : d.capabilities,
                          contextLength: d.contextLength, maxOutputTokens: d.maxOutputTokens,
                          inputPricePer1K: d.inputPricePer1K, outputPricePer1K: d.outputPricePer1K,
                          isFreeTier: d.isFreeTier || (p.freeQuota?.hasFreeTier ?? false) && d.isFreeTier,
                          health: .unknown, lastRefreshed: Date(), note: d.note)
            }
            try store.upsertModels(infos, for: p)
            try store.context.save()
            reloadFromStore()
            return RefreshReport(providerName: p.name, added: infos.count, total: infos.count)
        } catch let e as UpstreamError {
            if e.isUnauthorized { updateKeyStatus(providerID: p.id, status: .unauthorized, error: e.errorDescription) }
            else if e.isForbidden { updateKeyStatus(providerID: p.id, status: .forbidden, error: e.errorDescription) }
            else if e.isRateLimited { updateKeyStatus(providerID: p.id, status: .rateLimited, error: e.errorDescription) }
            return RefreshReport(providerName: p.name, added: 0, total: 0, error: e.errorDescription)
        } catch {
            return RefreshReport(providerName: p.name, added: 0, total: 0, error: error.localizedDescription)
        }
    }

    public func refreshAllEnabled() async -> [RefreshReport] {
        var out: [RefreshReport] = []
        for p in providers where p.enabled {
            out.append(await refreshModels(provider: p))
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return out
    }

    // MARK: - 连通性测试

    public func probe(provider p: Provider) async -> ProbeResult {
        guard let apiKey = key(for: p), !apiKey.isEmpty else {
            return ProbeResult(ok: false, latencyMs: 0, message: "尚未设置 API Key")
        }
        let adapter = AdapterFactory.adapter(for: p.protocolType)
        do {
            let call = try adapter.modelsCall(provider: p, apiKey: apiKey)
            let start = Date()
            let (_, response) = try await upstream.data(for: call, timeout: min(20, p.timeout))
            let ms = Date().timeIntervalSince(start) * 1000
            updateKeyStatus(providerID: p.id, status: .healthy)
            return ProbeResult(ok: true, latencyMs: ms, message: "模型目录可用", httpStatus: response.statusCode)
        } catch let e as UpstreamError {
            if e.isUnauthorized { updateKeyStatus(providerID: p.id, status: .unauthorized, error: e.errorDescription) }
            else if e.isForbidden { updateKeyStatus(providerID: p.id, status: .forbidden, error: e.errorDescription) }
            else if e.isRateLimited { updateKeyStatus(providerID: p.id, status: .rateLimited, error: e.errorDescription) }
            return ProbeResult(ok: false, latencyMs: 0, message: e.errorDescription ?? "失败", httpStatus: e.status)
        } catch {
            return ProbeResult(ok: false, latencyMs: 0, message: error.localizedDescription)
        }
    }

    public func test(model m: ModelInfo) async -> ProbeResult {
        guard let p = providers.first(where: { $0.id == m.providerID }) else {
            return ProbeResult(ok: false, latencyMs: 0, message: "找不到所属服务商")
        }
        var req = ChatRequest(model: m.modelID, messages: [ChatMessage(role: .user, content: "回复 OK 两个字母即可")], maxTokens: 16)
        req.stream = false
        let start = Date()
        do {
            let outcome = try await perform(request: req, pinned: m)
            let ms = Date().timeIntervalSince(start) * 1000
            updateModelHealth(m, health: .healthy, successRate: 1.0, latency: ms)
            return ProbeResult(ok: true, latencyMs: ms, message: "生成成功：" + outcome.response.text.prefix(40))
        } catch {
            let ms = Date().timeIntervalSince(start) * 1000
            updateModelHealth(m, health: .failing, successRate: 0, latency: ms)
            return ProbeResult(ok: false, latencyMs: ms, message: error.localizedDescription)
        }
    }

    // MARK: - 候选构建

    public func candidates(needing needs: Set<ModelCapability> = [.text]) -> [RouteCandidate] {
        models.filter { !$0.capabilitySet.isDisjoint(with: needs) }.compactMap { m in
            guard let p = providers.first(where: { $0.id == m.providerID }) else { return nil }
            return RouteCandidate(model: m, provider: p, hasUsableKey: p.hasUsableKey && key(for: p) != nil)
        }
    }

    // MARK: - 对话执行（含故障切换）

    public struct ChatOutcome: Sendable {
        public var response: ChatResponse
        public var attempts: Int
        public var switched: Bool
        public var lossyNotes: [String]
    }

    /// 非流式：走完整故障切换
    public func perform(request: ChatRequest, pinned: ModelInfo? = nil) async throws -> ChatOutcome {
        var order: [RouteCandidate]
        if let pinned, let p = providers.first(where: { $0.id == pinned.providerID }) {
            order = [RouteCandidate(model: pinned, provider: p, hasUsableKey: true)]
        } else {
            let decision = router.decide(candidates: candidates(), request: request)
            guard let chosen = decision.chosen else {
                throw AppError.noModel
            }
            order = decision.ranked.filter { !$0.blocked }.map { $0.candidate }
        }
        guard !order.isEmpty else { throw AppError.noModel }

        var attempt = 0
        var lastError: Error = AppError.noModel
        for candidate in order {
            attempt += 1
            guard let apiKey = key(for: candidate.provider), !apiKey.isEmpty else {
                lastError = AppError.keyNotFound(candidate.provider.name)
                continue
            }
            let adapter = AdapterFactory.adapter(for: candidate.provider.protocolType)
            let notes = adapter.lossyNotes(for: request)
            let start = Date()
            do {
                router.beginUse(candidate)
                defer { router.endUse(candidate) }
                monitor.markRequestStart(provider: candidate.provider.name, model: candidate.model.modelID)
                var req = request
                req.model = candidate.model.modelID
                req.stream = false
                let call = try adapter.chatCall(provider: candidate.provider, apiKey: apiKey, request: req)
                let (data, _) = try await upstream.data(for: call, timeout: candidate.provider.timeout)
                var resp = try adapter.parseChat(provider: candidate.provider, data: data)
                let ms = Date().timeIntervalSince(start) * 1000
                resp.latencyMs = ms
                resp.providerName = candidate.provider.name
                resp.switched = attempt > 1
                if let u = resp.usage { monitor.addTokens(max(u.totalTokens, u.completionTokens)) }
                monitor.markRequestEnd(ok: true, durationMs: ms)
                router.recordSuccess(model: candidate.model, keyRef: candidate.provider.keys.first?.keychainRef ?? "-")
                updateModelHealth(candidate.model, health: .healthy,
                                  successRate: min(1, candidate.model.successRate * 0.7 + 0.31), latency: ms)
                updateKeyStatus(providerID: candidate.provider.id, status: .healthy)
                await appendLog(model: candidate.model.modelID, provider: candidate.provider.name,
                                ms: ms, usage: resp.usage, status: 200, ok: true, switched: attempt > 1)
                if attempt > 1 { router.noteSwitch() }
                return ChatOutcome(response: resp, attempts: attempt, switched: attempt > 1, lossyNotes: notes)
            } catch {
                lastError = error
                let failMs = Date().timeIntervalSince(start) * 1000
                monitor.markRequestEnd(ok: false, durationMs: failMs, errorNote: error.localizedDescription)
                let ue = error as? UpstreamError
                router.recordFailure(model: candidate.model, keyRef: candidate.provider.keys.first?.keychainRef ?? "-",
                                     error: ue ?? .network(error.localizedDescription))
                updateModelHealth(candidate.model, health: .degraded,
                                  successRate: max(0, candidate.model.successRate * 0.6), latency: nil)
                await appendLog(model: candidate.model.modelID, provider: candidate.provider.name,
                                ms: failMs, usage: nil, status: ue?.status ?? 0, ok: false, switched: false,
                                errorNote: error.localizedDescription)
                if attempt < order.count, let delay = router.policy.delay(afterAttempt: attempt - 1) {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continue
            }
        }
        throw lastError
    }

    /// 流式：失败只在「首字未出」时切换，已输出后不重放（避免重复内容）
    public func performStreaming(request: ChatRequest, pinned: ModelInfo? = nil)
        -> AsyncThrowingStream<StreamOutcome, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                let order: [RouteCandidate]
                if let pinned, let p = providers.first(where: { $0.id == pinned.providerID }) {
                    order = [RouteCandidate(model: pinned, provider: p, hasUsableKey: true)]
                } else {
                    let decision = router.decide(candidates: candidates(), request: request)
                    guard let chosen = decision.chosen else {
                        continuation.finish(throwing: AppError.noModel); return
                    }
                    order = decision.ranked.filter { !$0.blocked }.map { $0.candidate }
                }
                guard !order.isEmpty else { continuation.finish(throwing: AppError.noModel); return }

                var emittedAny = false
                var lastError: Error = AppError.noModel
                for (idx, candidate) in order.enumerated() {
                    guard let apiKey = key(for: candidate.provider), !apiKey.isEmpty else {
                        lastError = AppError.keyNotFound(candidate.provider.name); continue
                    }
                    let adapter = AdapterFactory.adapter(for: candidate.provider.protocolType)
                    let notes = adapter.lossyNotes(for: request)
                    var req = request
                    req.model = candidate.model.modelID
                    req.stream = true
                    emittedAny = false
                    let start = Date()
                    router.beginUse(candidate)
                    monitor.markRequestStart(provider: candidate.provider.name, model: candidate.model.modelID)
                    do {
                        let call = try adapter.chatCall(provider: candidate.provider, apiKey: apiKey, request: req)
                        var text = ""
                        var usage: UsageInfo?
                        var finish: String?
                        for try await piece in upstream.streamLines(call: call, timeout: candidate.provider.timeout,
                                                                    adapter: adapter, provider: candidate.provider) {
                            if !piece.text.isEmpty {
                                emittedAny = true
                                text += piece.text
                                monitor.addTokens(Self.approxTokens(piece.text))
                                continuation.yield(.delta(piece.text, provider: candidate.provider.name,
                                                            model: candidate.model.modelID, switched: idx > 0))
                            }
                            if let u = piece.usage { usage = u }
                            if let f = piece.finish { finish = f }
                            if piece.isDone { break }
                        }
                        let ms = Date().timeIntervalSince(start) * 1000
                        let resp = ChatResponse(id: UUID().uuidString, model: candidate.model.modelID,
                                                providerName: candidate.provider.name, text: text,
                                                finishReason: finish, usage: usage, latencyMs: ms,
                                                switched: idx > 0)
                        monitor.markRequestEnd(ok: true, durationMs: ms)
                        router.recordSuccess(model: candidate.model, keyRef: candidate.provider.keys.first?.keychainRef ?? "-")
                        updateModelHealth(candidate.model, health: .healthy,
                                          successRate: min(1, candidate.model.successRate * 0.7 + 0.31), latency: ms)
                        updateKeyStatus(providerID: candidate.provider.id, status: .healthy)
                        await appendLog(model: candidate.model.modelID, provider: candidate.provider.name,
                                        ms: ms, usage: usage, status: 200, ok: true, switched: idx > 0)
                        if idx > 0 { router.noteSwitch() }
                        continuation.yield(.done(resp, lossyNotes: notes))
                        continuation.finish()
                        router.endUse(candidate)
                        return
                    } catch {
                        router.endUse(candidate)
                        lastError = error
                        let ue = error as? UpstreamError
                        monitor.markRequestEnd(ok: false, durationMs: Date().timeIntervalSince(start) * 1000,
                                               errorNote: error.localizedDescription)
                        router.recordFailure(model: candidate.model, keyRef: candidate.provider.keys.first?.keychainRef ?? "-",
                                             error: ue ?? .network(error.localizedDescription))
                        updateModelHealth(candidate.model, health: .degraded,
                                          successRate: max(0, candidate.model.successRate * 0.6), latency: nil)
                        await appendLog(model: candidate.model.modelID, provider: candidate.provider.name,
                                        ms: Date().timeIntervalSince(start) * 1000, usage: nil,
                                        status: ue?.status ?? 0, ok: false, switched: false,
                                        errorNote: error.localizedDescription)
                        if emittedAny {
                            // 已经有内容输出：不重放整段请求，直接以错误结束
                            continuation.finish(throwing: error)
                            return
                        }
                        if idx + 1 < order.count {
                            continuation.yield(.switching(from: candidate.provider.name, to: order[idx + 1].provider.name,
                                                          reason: error.localizedDescription))
                            if let delay = router.policy.delay(afterAttempt: idx) {
                                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            }
                        }
                        continue
                    }
                }
                continuation.finish(throwing: lastError)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public enum StreamOutcome: Sendable {
        case delta(String, provider: String, model: String, switched: Bool)
        case done(ChatResponse, lossyNotes: [String])
        case switching(from: String, to: String, reason: String)
    }

    /// 粗略 token 估算（上游未返回 usage 时用于监控显示）
    public static func approxTokens(_ s: String) -> Int {
        let perChar = s.contains(where: { $0.isASCII }) ? 4.0 : 1.6
        return max(1, Int(round(Double(s.count) / perChar)))
    }

    // MARK: - 日志

    public func appendLog(model: String, provider: String, ms: Double, usage: UsageInfo?,
                          status: Int, ok: Bool, switched: Bool, errorNote: String? = nil) async {
        let log = DBRequestLog(modelID: model, providerName: provider, durationMs: ms,
                               promptTokens: usage?.promptTokens ?? 0,
                               completionTokens: usage?.completionTokens ?? 0,
                               totalTokens: usage?.totalTokens ?? 0,
                               httpStatus: status, switched: switched, ok: ok, errorNote: errorNote)
        try? store.appendLog(log)
        try? store.context.save()
        recentLogs.insert(log, at: 0)
        if recentLogs.count > 400 { recentLogs.removeLast(recentLogs.count - 400) }
    }

    public func refreshLogs() {
        recentLogs = (try? store.fetchLogs(limit: 300)) ?? []
    }

    // MARK: - 网关 Token

    public var gatewayToken: String {
        let ref = "gateway/token"
        if let t = keychain.get(ref) { return t }
        let t = "fr_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        keychain.set(t, for: ref)
        return t
    }

    public var maskedGatewayToken: String { KeychainStore.mask(gatewayToken) }
}
