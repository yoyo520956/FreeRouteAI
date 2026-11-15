import Foundation

// MARK: - Agent 统一核心配置与结果

/// 单次 Agent 运行的配置（由调用方根据 UI/网关/CLI 组装）
public struct AgentRunConfig: Sendable {
    public var taskId: String
    public var goal: String                      // 用户原始目标，用于报告
    public var model: String                     // 形如 "providerID/modelID"
    public var messages: [ChatMessage]           // 已包含 system / 历史 / 当前 user
    public var protocolType: ProviderProtocolType
    public var ctx: ToolContext                  // 真实执行上下文（权限、设备、目录、网关快照等）
    public var maxSteps: Int = 20                // 最大模型调用轮数（防止死循环）
    public var maxResultChars: Int = 8000        // 单步工具结果截断
    public var toolTimeout: TimeInterval = 30
    public var includeTools: Bool = true         // 是否在请求中透传 tools
    public var systemPrompt: String?             // 额外注入的 system 提示（可空）
    public var stream: Bool = false              // 是否启用 SSE 流式输出
    public var pinned: ModelInfo?                // 已解析的目标模型（避免每轮重复路由）
    public var cancellation: Task<Void, Never>?  // 外部取消信号（可空）

    public init(taskId: String = "task_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(),
                goal: String, model: String, messages: [ChatMessage], protocolType: ProviderProtocolType,
                ctx: ToolContext, maxSteps: Int = 20, maxResultChars: Int = 8000,
                toolTimeout: TimeInterval = 30, includeTools: Bool = true, systemPrompt: String? = nil,
                stream: Bool = false, pinned: ModelInfo? = nil, cancellation: Task<Void, Never>? = nil) {
        self.taskId = taskId; self.goal = goal; self.model = model; self.messages = messages
        self.protocolType = protocolType; self.ctx = ctx
        self.maxSteps = maxSteps; self.maxResultChars = maxResultChars
        self.toolTimeout = toolTimeout; self.includeTools = includeTools
        self.systemPrompt = systemPrompt; self.stream = stream; self.pinned = pinned; self.cancellation = cancellation
    }
}

/// 单次 Agent 运行的完整结果（含步骤、工具调用、最终答案）
public struct AgentRunResult: Sendable {
    public var taskId: String
    public var goal: String
    public var status: AgentTaskStatus
    public var finalAnswer: String
    public var error: String?
    public var providerName: String
    public var model: String
    public var steps: [AgentStepRecord]
    public var events: [AgentEvent]
    public var toolCallCount: Int
    public var modelCallCount: Int
    public var durationMs: Double
    public var startedAt: Date
    public var finishedAt: Date

    public init(taskId: String, goal: String, status: AgentTaskStatus,
                finalAnswer: String, error: String?, providerName: String, model: String,
                steps: [AgentStepRecord], events: [AgentEvent],
                toolCallCount: Int, modelCallCount: Int,
                durationMs: Double, startedAt: Date, finishedAt: Date) {
        self.taskId = taskId; self.goal = goal; self.status = status; self.finalAnswer = finalAnswer
        self.error = error; self.providerName = providerName; self.model = model
        self.steps = steps; self.events = events
        self.toolCallCount = toolCallCount; self.modelCallCount = modelCallCount
        self.durationMs = durationMs; self.startedAt = startedAt; self.finishedAt = finishedAt
    }

    /// 报告用 JSON（供 /v1/agent/tasks/{id} 返回）
    public var reportJSON: [String: Any] {
        [
            "task_id": taskId,
            "goal": goal,
            "status": status.rawValue,
            "created_at": AgentTime.iso(startedAt),
            "finished_at": AgentTime.iso(finishedAt),
            "duration_ms": durationMs,
            "final_answer": finalAnswer,
            "error": error as Any,
            "tool_call_count": toolCallCount,
            "model_call_count": modelCallCount,
            "steps": steps.map { $0.asJSONObject },
            "events": events.map { $0.asJSONObject }
        ]
    }
}

// MARK: - 上游协议（AppState 实现）

/// AgentRunner 只依赖这个协议，避免直接耦合 AppState / ProviderCatalog 等庞大类型
public protocol AgentUpstream: Sendable {
    /// 发起一次非流式上游调用（含故障切换、Token 统计、日志）
    func agentCall(request: ChatRequest, pinned: ModelInfo?) async throws -> AppState.ChatOutcome
}

// MARK: - AgentRunner（核心循环）

public final class AgentRunner: @unchecked Sendable {
    public init() {}

    /// 执行完整的 Agent 循环：模型 → 工具 → 模型 → … → 最终答案
    /// - Parameters:
    ///   - config: 运行配置
    ///   - upstream: 实现了 AgentUpstream 的上游（AppState）
    ///   - onEvent: 每个 AgentEvent 实时回调（供 SSE、UI、日志）
    public func run(config: AgentRunConfig,
                    upstream: AgentUpstream,
                    onEvent: @escaping @Sendable (AgentEvent) -> Void) async -> AgentRunResult {
        let startedAt = Date()
        var seq = 0
        var stepIndex = 0
        var steps: [AgentStepRecord] = []
        var events: [AgentEvent] = []
        var toolCallCount = 0
        var modelCallCount = 0
        var messages = config.messages
        var currentProvider = ""
        var currentModel = ""

        func emit(_ kind: AgentEventKind, step: Int, title: String, detail: String = "",
                  toolName: String? = nil, callId: String? = nil) {
            let ev = AgentEvent(taskId: config.taskId, seq: seq, kind: kind,
                                stepIndex: step, title: title, detail: detail,
                                toolName: toolName, callId: callId)
            seq += 1
            events.append(ev)
            onEvent(ev)
        }

        // 解析 model 字符串：可能是 "modelID" 或 "providerID/modelID"
        let modelParts = config.model.split(separator: "/")
        let targetModelID = String(modelParts.last ?? Substring(config.model))

        // 若有 systemPrompt，在开头插入（不覆盖原有 system）
        if let sp = config.systemPrompt, !sp.isEmpty {
            messages.insert(ChatMessage(role: .system, content: sp), at: 0)
        }

        // 循环
        for _ in 0..<config.maxSteps {
            if let c = config.cancellation, c.isCancelled {
                break
            }
            // 组装请求
            var req = ChatRequest(
                model: targetModelID,
                messages: messages,
                temperature: nil,   // 由上游按模型默认值决定
                topP: nil,
                maxTokens: nil,
                stop: nil,
                stream: false,
                responseFormatJSON: nil,
                toolsJSON: config.includeTools ? ToolCatalog.openAIToolsJSON().jsonString : nil,
                user: nil
            )

            // 发起上游调用
            modelCallCount += 1
            emit(.model, step: stepIndex, title: "模型调用 #\(modelCallCount)",
                 detail: "model=\(targetModelID) provider=\(currentProvider.isEmpty ? "路由中" : currentProvider)")

            let outcome: AppState.ChatOutcome
            do {
                outcome = try await upstream.agentCall(request: req, pinned: config.pinned)
            } catch {
                let errMsg = error.localizedDescription
                emit(.error, step: stepIndex, title: "上游错误", detail: errMsg)
                let finished = Date()
                return AgentRunResult(
                    taskId: config.taskId, goal: config.goal, status: .failed,
                    finalAnswer: "", error: errMsg,
                    providerName: currentProvider, model: targetModelID,
                    steps: steps, events: events,
                    toolCallCount: toolCallCount, modelCallCount: modelCallCount,
                    durationMs: finished.timeIntervalSince(startedAt) * 1000,
                    startedAt: startedAt, finishedAt: finished
                )
            }

            currentProvider = outcome.response.providerName
            currentModel = outcome.response.model
            modelCallCount += 0 // already counted above

            // 若无工具调用 → 结束
            if outcome.response.toolCalls.isEmpty {
                let answer = outcome.response.text
                let finished = Date()
                emit(.done, step: stepIndex, title: "完成", detail: answer)
                return AgentRunResult(
                    taskId: config.taskId, goal: config.goal, status: .completed,
                    finalAnswer: answer, error: nil,
                    providerName: currentProvider, model: targetModelID,
                    steps: steps, events: events,
                    toolCallCount: toolCallCount, modelCallCount: modelCallCount,
                    durationMs: finished.timeIntervalSince(startedAt) * 1000,
                    startedAt: startedAt, finishedAt: finished
                )
            }

            // 有工具调用：逐个执行
            let assistantMsg = ChatMessage(role: .assistant, content: outcome.response.text,
                                           toolCalls: outcome.response.toolCalls)
            messages.append(assistantMsg)

            var stepCalls: [ToolCall] = []
            var stepResults: [ToolResult] = []
            var stepSummaryParts: [String] = []

            for call in outcome.response.toolCalls {
                toolCallCount += 1
                let toolCall = ToolCall(name: call.name, arguments: call.arguments)
                stepCalls.append(toolCall)

                emit(.toolCall, step: stepIndex, title: "工具调用",
                     detail: "\(call.name)(\(call.arguments.jsonString))",
                     toolName: call.name, callId: call.id)

                // 执行工具（真实执行，ToolEngine 内部已做权限/确认/SSRF 校验）
                var toolCtx = config.ctx
                toolCtx.maxResultChars = config.maxResultChars
                toolCtx.toolTimeout = config.toolTimeout
                let result = await ToolEngine.execute(toolCall, ctx: toolCtx)
                stepResults.append(result)

                // 回灌工具结果消息
                let tr = ToolResultTurn(callId: call.id, name: call.name,
                                        content: result.content, ok: result.ok)
                messages.append(ChatMessage(role: .tool, content: result.content, toolResult: tr))

                emit(.toolResult, step: stepIndex, title: "工具结果",
                     detail: result.ok ? "OK (\(result.content.count) 字符)" : "失败：\(result.error ?? "未知")",
                     toolName: call.name, callId: call.id)

                stepSummaryParts.append("\(call.name): \(result.ok ? "OK" : "ERR")")
            }

            // 记录步骤
            let stepRecord = AgentStepRecord(
                index: stepIndex, kind: "tool_loop",
                summary: stepSummaryParts.joined(separator: "; "),
                calls: stepCalls, results: stepResults,
                startedAt: Date(), finishedAt: Date()
            )
            steps.append(stepRecord)
            stepIndex += 1
        }

        // 超过最大步数
        let finished = Date()
        emit(.error, step: stepIndex, title: "达到最大步数", detail: "已执行 \(config.maxSteps) 步仍未结束")
        return AgentRunResult(
            taskId: config.taskId, goal: config.goal, status: .timedOut,
            finalAnswer: "", error: "达到最大步数 \(config.maxSteps)",
            providerName: currentProvider, model: targetModelID,
            steps: steps, events: events,
            toolCallCount: toolCallCount, modelCallCount: modelCallCount,
            durationMs: finished.timeIntervalSince(startedAt) * 1000,
            startedAt: startedAt, finishedAt: finished
        )
    }
}