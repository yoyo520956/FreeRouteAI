import Foundation

// MARK: - AgentBridge：AppState ←→ AgentRunner 的桥接层
// 1. 让 AppState 实现 AgentUpstream（无侵入式扩展）
// 2. 从 AppState 采集真实状态构建 ToolContext
// 3. 供网关 / UI / CLI 统一调用

extension AppState: AgentUpstream {
    /// 代理给现有 perform（含故障切换、Token 统计、日志、Key 健康度）
    public func agentCall(request: ChatRequest, pinned: ModelInfo? = nil) async throws -> ChatOutcome {
        try await perform(request: request, pinned: pinned)
    }
}

/// 采集 Agent 所需的真实执行上下文（ToolContext）
/// 由调用方（GatewayController / HomeView / CLI）在 MainActor 上同步获取
public struct AgentContextFactory {
    private init() {}

    /// 从 AppState 快照构建 ToolContext
    /// - Parameter app: 必须在 MainActor 上调用（AppState 是 @MainActor）
    @MainActor
    public static func makeContext(from app: AppState) -> ToolContext {
        var ctx = ToolContext()
        ctx.authorizedRoot = AuthorizedFiles.root().path
        ctx.sessionCount = app.gateway.status.connectionCount // 近似：网关连接数
        ctx.recentLogs = app.recentLogs.prefix(50).map { log in
            "[\(log.status)] \(log.model) \(log.latencyMs)ms \(log.promptTokens + log.completionTokens)tok"
        }
        ctx.modelNames = app.models.map { "\($0.providerName)/\($0.modelID)" }
        ctx.tokenSnapshot = Dictionary(uniqueKeysWithValues:
            app.recentLogs.suffix(20).map { ($0.model, "\($0.promptTokens + $0.completionTokens) tok") }
        )
        ctx.gatewaySnapshot = app.gateway.status
        ctx.approvedDevices = ToolPermissionStore().devices().filter { $0.approved }
        ctx.allowedPermissions = ToolPermissionStore().enabledPermissions
        ctx.allowPrivateHTTP = ToolPermissionStore().allowPrivateHTTP
        ctx.remoteExecutorURL = ToolPermissionStore().remoteExecutorURL
        ctx.confirmations = [] // 由 UI 在需要时写入
        ctx.maxResultChars = 8000
        ctx.toolTimeout = 30

        // 视觉模型端点：从已配置模型里挑一个带 .vision 能力的
        if let vis = app.models.first(where: { $0.capabilities.contains(.vision) }),
           let prov = app.providers.first(where: { $0.id == vis.providerID }),
           let keyRef = prov.keys.first(where: { $0.status == .healthy || $0.status == .unknown || $0.status == .rateLimited }),
           let apiKey = try? app.keychain.get(keyRef) {
            // 判断协议类型，构造端点
            let base = prov.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/") ?
                String(prov.baseURL.dropLast()) : prov.baseURL
            let path = prov.requestPath ?? "/chat/completions"
            let endpoint = base + path
            let fmt: ImageAPIFormat = (prov.protocolType == .gemini) ? .geminiREST : .openAICompatible
            ctx.visualModel = VisualModelEndpoint(
                providerName: prov.name,
                modelID: vis.modelID,
                endpoint: endpoint,
                apiKey: apiKey,
                format: fmt,
                customHeaders: prov.customHeaders
            )
        }
        return ctx
    }
}

/// 网关 / UI 侧：给定目标模型字符串，解析出 providerID 与 modelID（供 AgentRunner 使用）
/// 约定：modelStr 为 "providerID/modelID" 或单纯 "modelID"（此时走路由）
public struct AgentModelResolver {
    public static func resolve(_ modelStr: String, in app: AppState) -> (providerID: UUID?, modelID: String) {
        let parts = modelStr.split(separator: "/", maxSplits: 1)
        if parts.count == 2, let pid = UUID(uuidString: String(parts[0])) {
            return (pid, String(parts[1]))
        }
        return (nil, modelStr)
    }
}