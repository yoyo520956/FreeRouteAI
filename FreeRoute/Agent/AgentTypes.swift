import Foundation

// MARK: - 权限
// 工具权限是独立维度：模型的输出永远不能提升权限。ToolEngine 在真正执行前
// 用 ToolGuard 复核一次，网关请求与原生聊天走的是同一份复核逻辑。

public enum ToolPermission: String, Codable, CaseIterable, Sendable {
    case none, network, fileRead, fileWrite, codeExec, http, admin

    public var label: String {
        switch self {
        case .none: return "无特殊权限"
        case .network: return "联网搜索"
        case .fileRead: return "读取授权文件"
        case .fileWrite: return "写入授权文件"
        case .codeExec: return "代码执行"
        case .http: return "访问公开 HTTP"
        case .admin: return "设备与网关管理"
        }
    }

    public var detail: String {
        switch self {
        case .none: return "纯本地计算，不访问外部资源"
        case .network: return "仅允许访问搜索引擎与已打开的公开网页"
        case .fileRead: return "仅允许读取用户导入到授权目录的文件"
        case .fileWrite: return "写入前必须逐次确认，且只能写入授权目录"
        case .codeExec: return "JavaScriptCore 沙箱；Python 需外部执行器"
        case .http: return "默认阻止回环、私网与云元数据地址"
        case .admin: return "仅返回本机已授权设备与网关状态，不修改系统"
        }
    }
}

public enum ToolGuardVerdict: String, Codable, Sendable {
    case allowed, needsConfirmation, denied
}

public struct ToolGuardDecision: Codable, Hashable, Sendable {
    public var verdict: ToolGuardVerdict
    public var reason: String
    public var confirmationToken: String?
    public init(verdict: ToolGuardVerdict, reason: String = "", confirmationToken: String? = nil) {
        self.verdict = verdict; self.reason = reason; self.confirmationToken = confirmationToken
    }
}

// MARK: - 工具描述与调用

/// 单个工具的注册信息。parameters 是标准 JSON Schema（object），
/// 直接用于 OpenAI tools / Gemini functionDeclarations / 本机参数校验。
public struct ToolSpec: Identifiable, Codable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var title: String
    public var group: String
    public var summary: String
    public var parameters: JSONValue
    public var permission: ToolPermission
    public var requiresConfirmation: Bool
    public var timeout: TimeInterval

    public init(name: String, title: String, group: String, summary: String,
                parameters: JSONValue, permission: ToolPermission,
                requiresConfirmation: Bool = false, timeout: TimeInterval = 20) {
        self.name = name; self.title = title; self.group = group; self.summary = summary
        self.parameters = parameters; self.permission = permission
        self.requiresConfirmation = requiresConfirmation; self.timeout = timeout
    }
}

public struct ToolCall: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var arguments: JSONValue

    public init(id: String = "call_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12),
                name: String, arguments: JSONValue = .object([:])) {
        self.id = id; self.name = name; self.arguments = arguments
    }

    public func argString(_ key: String) -> String? { arguments[key]?.string }
    public func argInt(_ key: String) -> Int? { arguments[key]?.number.map { Int($0) } }
    public func argBool(_ key: String) -> Bool? { arguments[key]?.bool }
}

/// 一次工具调用的完整留痕。evidence 记录真实执行证据（HTTP 状态码、实际 URL、
/// 读取到的字节数、OCR 引擎、JSC 求值结果类型），不是模型编造的"已完成"。
public struct ToolResult: Codable, Hashable, Sendable {
    public var callId: String
    public var name: String
    public var ok: Bool
    public var content: String
    public var evidence: String
    public var durationMs: Double
    public var startedAt: Date
    public var error: String?
    public var truncated: Bool

    public init(callId: String, name: String, ok: Bool, content: String,
                evidence: String = "", durationMs: Double = 0, startedAt: Date = Date(),
                error: String? = nil, truncated: Bool = false) {
        self.callId = callId; self.name = name; self.ok = ok; self.content = content
        self.evidence = evidence; self.durationMs = durationMs; self.startedAt = startedAt
        self.error = error; self.truncated = truncated
    }

    public var asJSONObject: [String: Any] {
        [
            "tool_call_id": callId,
            "name": name,
            "ok": ok,
            "content": content,
            "evidence": evidence,
            "duration_ms": durationMs,
            "started_at": AgentTime.iso(startedAt),
            "error": error as Any,
            "truncated": truncated
        ]
    }
}

// MARK: - 权限存储与设备批准

public struct DeviceRecord: Codable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var remoteAddress: String
    public var approved: Bool
    public var firstSeen: Date
    public var lastSeen: Date
    public init(id: String, label: String, remoteAddress: String, approved: Bool,
                firstSeen: Date = Date(), lastSeen: Date = Date()) {
        self.id = id; self.label = label; self.remoteAddress = remoteAddress
        self.approved = approved; self.firstSeen = firstSeen; self.lastSeen = lastSeen
    }
    public var asJSONObject: [String: Any] {
        ["id": id, "label": label, "remote_address": remoteAddress,
         "approved": approved, "first_seen": AgentTime.iso(firstSeen), "last_seen": AgentTime.iso(lastSeen)]
    }
}

/// 独立于 AppSettings 的工具权限存储：权限开关、危险操作确认令牌、设备批准、
/// 远程代码执行器。密钥类信息永远不进 UserDefaults。
public final class ToolPermissionStore: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let enabledKey = "freeroute.tool.permissions.v1"
    private let confirmKey = "freeroute.tool.confirmations.v1"
    private let deviceKey = "freeroute.tool.devices.v1"
    private let lock = NSLock()

    public init() {}

    public var enabledPermissions: Set<ToolPermission> {
        lock.lock(); defer { lock.unlock() }
        let raw = defaults.stringArray(forKey: enabledKey)
            ?? [ToolPermission.none.rawValue, ToolPermission.network.rawValue,
                ToolPermission.fileRead.rawValue, ToolPermission.codeExec.rawValue,
                ToolPermission.http.rawValue]
        return Set(raw.compactMap { ToolPermission(rawValue: $0) })
    }

    public func setPermission(_ p: ToolPermission, enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        var set = Set(defaults.stringArray(forKey: enabledKey)
                      ?? [ToolPermission.none.rawValue, ToolPermission.network.rawValue,
                          ToolPermission.fileRead.rawValue, ToolPermission.codeExec.rawValue,
                          ToolPermission.http.rawValue])
        if enabled { set.insert(p.rawValue) } else { set.remove(p.rawValue) }
        defaults.set(Array(set).sorted(), forKey: enabledKey)
    }

    public var allowPrivateHTTP: Bool {
        get { lock.lock(); defer { lock.unlock() }; return defaults.bool(forKey: "freeroute.tool.allowPrivateHTTP") }
        set { lock.lock(); defer { lock.unlock() }; defaults.set(newValue, forKey: "freeroute.tool.allowPrivateHTTP") }
    }

    public var remoteExecutorURL: String? {
        get { lock.lock(); defer { lock.unlock() }; return defaults.string(forKey: "freeroute.tool.remoteExecutor") }
        set { lock.lock(); defer { lock.unlock() }; defaults.set(newValue, forKey: "freeroute.tool.remoteExecutor") }
    }

    /// 用户明确授权的一次性操作令牌。写入文件 / 发送外部数据必须带上它。
    public func grant(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        var set = Set(defaults.stringArray(forKey: confirmKey) ?? [])
        set.insert(token)
        defaults.set(Array(set).sorted(), forKey: confirmKey)
    }

    public func hasGrant(_ token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        lock.lock(); defer { lock.unlock() }
        return (defaults.stringArray(forKey: confirmKey) ?? []).contains(token)
    }

    public func consume(_ token: String) {
        lock.lock(); defer { lock.unlock() }
        var set = Set(defaults.stringArray(forKey: confirmKey) ?? [])
        set.remove(token)
        defaults.set(Array(set).sorted(), forKey: confirmKey)
    }

    public func devices() -> [DeviceRecord] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: deviceKey),
              let list = try? JSONDecoder().decode([DeviceRecord].self, from: data) else { return [] }
        return list
    }

    public func recordDevice(_ address: String) -> DeviceRecord {
        lock.lock(); defer { lock.unlock() }
        var list: [DeviceRecord] = []
        if let data = defaults.data(forKey: deviceKey),
           let saved = try? JSONDecoder().decode([DeviceRecord].self, from: data) { list = saved }
        if let idx = list.firstIndex(where: { $0.remoteAddress == address }) {
            list[idx].lastSeen = Date()
            defaults.set(try? JSONEncoder().encode(list), forKey: deviceKey)
            return list[idx]
        }
        let rec = DeviceRecord(id: "dev_" + UUID().uuidString.prefix(8).lowercased(),
                               label: "未命名设备", remoteAddress: address, approved: false)
        list.append(rec)
        defaults.set(try? JSONEncoder().encode(list), forKey: deviceKey)
        return rec
    }

    public func approveDevice(_ id: String, approved: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: deviceKey),
              var list = try? JSONDecoder().decode([DeviceRecord].self, from: data) else { return }
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].approved = approved
        defaults.set(try? JSONEncoder().encode(list), forKey: deviceKey)
    }

    public func renameDevice(_ id: String, label: String) {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: deviceKey),
              var list = try? JSONDecoder().decode([DeviceRecord].self, from: data) else { return }
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return }
        list[idx].label = label
        defaults.set(try? JSONEncoder().encode(list), forKey: deviceKey)
    }
}

// MARK: - 视觉模型端点（image.understand 用）
// 由 AgentRunner 从模型配置解析后填入；未配置时该字段为 nil，工具返回诚实错误，
// 绝不伪造"分析结果"。

public enum ImageAPIFormat: String, Codable, Sendable {
    case openAICompatible   // /chat/completions，image_url data URL
    case geminiREST         // :generateContent，inlineData
}

public struct VisualModelEndpoint: Sendable {
    public var providerName: String
    public var modelID: String
    public var endpoint: String        // 完整 URL（chat completions 或 generateContent）
    public var apiKey: String
    public var format: ImageAPIFormat
    public var customHeaders: [String: String]
    public init(providerName: String, modelID: String, endpoint: String,
                apiKey: String, format: ImageAPIFormat, customHeaders: [String: String] = [:]) {
        self.providerName = providerName; self.modelID = modelID; self.endpoint = endpoint
        self.apiKey = apiKey; self.format = format; self.customHeaders = customHeaders
    }
}

// MARK: - 工具执行上下文（真实状态快照，不允许模型伪造）

public struct ToolContext: Sendable {
    public var authorizedRoot: String = ""
    public var sessionCount: Int = 0
    public var recentLogs: [String] = []
    public var modelNames: [String] = []
    public var tokenSnapshot: [String: String] = [:]
    public var gatewaySnapshot: [String: String] = [:]
    public var approvedDevices: [DeviceRecord] = []
    public var allowedPermissions: Set<ToolPermission> = []
    public var allowPrivateHTTP: Bool = false
    public var remoteExecutorURL: String?
    public var confirmations: [String] = []
    public var maxResultChars: Int = 6000
    public var toolTimeout: TimeInterval = 20
    public var visualModel: VisualModelEndpoint? = nil
    public init() {}
}

// MARK: - 参数校验与权限复核

public enum ToolGuard {
    /// 按 JSON Schema 校验必填项与基础类型。返回 nil 表示通过。
    public static func validate(_ spec: ToolSpec, _ args: JSONValue) -> String? {
        guard case .object(let obj) = args else { return "参数必须是 JSON 对象" }
        guard case .object(let schema) = spec.parameters,
              let props = schema["properties"]?.object,
              let required = schema["required"]?.array else { return nil }
        for r in required.compactMap({ $0.string }) {
            guard obj[r] != nil, !isNull(obj[r]!) else { return "缺少必填参数 \(r)" }
        }
        for (key, def) in props {
            guard let v = obj[key], !isNull(v) else { continue }
            let want = def["type"]?.string
            switch want {
            case "string": if v.string == nil { return "参数 \(key) 必须是字符串" }
            case "number", "integer": if v.number == nil { return "参数 \(key) 必须是数字" }
            case "boolean": if v.bool == nil { return "参数 \(key) 必须是布尔值" }
            case "array": if v.array == nil { return "参数 \(key) 必须是数组" }
            case "object": if v.object == nil { return "参数 \(key) 必须是对象" }
            default: break
            }
            if let enums = def["enum"]?.array, !enums.isEmpty,
               !enums.contains(where: { $0.string == v.string }) {
                return "参数 \(key) 的取值不在允许列表内"
            }
        }
        return nil
    }

    private static func isNull(_ v: JSONValue) -> Bool { if case .null = v { return true }; return false }

    /// 权限复核：模型不能通过输出 JSON 绕过开关。
    public static func check(_ spec: ToolSpec, _ call: ToolCall, _ ctx: ToolContext) -> ToolGuardDecision {
        if ctx.allowedPermissions.contains(spec.permission) == false &&
            spec.permission != .none {
            return ToolGuardDecision(verdict: .denied,
                                     reason: "权限「\(spec.permission.label)」未开启；请在设置 → Agent 与工具里开启")
        }
        if spec.requiresConfirmation {
            let token = call.argString("_confirm")
            if !ctx.confirmations.contains(where: { $0 == token }) {
                let t = "confirm_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
                return ToolGuardDecision(verdict: .needsConfirmation,
                                         reason: "该操作会写入文件或向外部发送数据，需要用户明确授权",
                                         confirmationToken: t)
            }
        }
        return ToolGuardDecision(verdict: .allowed, reason: "权限检查通过")
    }
}

// MARK: - 任务与事件

public enum AgentEventKind: String, Codable, Sendable {
    case step, toolCall, toolResult, model, error, done, cancelled
}

public struct AgentEvent: Codable, Hashable, Sendable {
    public var taskId: String
    public var seq: Int
    public var at: Date
    public var kind: AgentEventKind
    public var stepIndex: Int
    public var title: String
    public var detail: String
    public var toolName: String?
    public var callId: String?

    public init(taskId: String, seq: Int, at: Date = Date(), kind: AgentEventKind,
                stepIndex: Int, title: String, detail: String = "",
                toolName: String? = nil, callId: String? = nil) {
        self.taskId = taskId; self.seq = seq; self.at = at; self.kind = kind
        self.stepIndex = stepIndex; self.title = title; self.detail = detail
        self.toolName = toolName; self.callId = callId
    }

    public var asJSONObject: [String: Any] {
        var o: [String: Any] = [
            "task_id": taskId, "seq": seq, "at": AgentTime.iso(at),
            "kind": kind.rawValue, "step_index": stepIndex,
            "title": title, "detail": detail
        ]
        if let toolName { o["tool_name"] = toolName }
        if let callId { o["tool_call_id"] = callId }
        return o
    }
}

public enum AgentTaskStatus: String, Codable, Sendable {
    case running, completed, failed, cancelled, timedOut
}

public struct AgentStepRecord: Codable, Hashable, Sendable {
    public var index: Int
    public var kind: String
    public var summary: String
    public var calls: [ToolCall]
    public var results: [ToolResult]
    public var startedAt: Date
    public var finishedAt: Date?
    public var error: String?
    public init(index: Int, kind: String, summary: String,
                calls: [ToolCall] = [], results: [ToolResult] = [],
                startedAt: Date = Date(), finishedAt: Date? = nil, error: String? = nil) {
        self.index = index; self.kind = kind; self.summary = summary
        self.calls = calls; self.results = results; self.startedAt = startedAt
        self.finishedAt = finishedAt; self.error = error
    }
    public var asJSONObject: [String: Any] {
        ["index": index, "kind": kind, "summary": summary,
         "tool_calls": calls.map { ["id": $0.id, "name": $0.name, "arguments": AgentJSON.any($0.arguments)] as [String: Any] },
         "tool_results": results.map { $0.asJSONObject },
         "started_at": AgentTime.iso(startedAt),
         "finished_at": finishedAt.map { AgentTime.iso($0) } as Any,
         "error": error as Any]
    }
}

public struct AgentTask: Codable, Hashable, Sendable {
    public var id: String
    public var goal: String
    public var status: AgentTaskStatus
    public var createdAt: Date
    public var finishedAt: Date?
    public var steps: [AgentStepRecord]
    public var events: [AgentEvent]
    public var finalAnswer: String
    public var error: String?
    public var toolCallCount: Int
    public var modelCallCount: Int

    public init(id: String = "task_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(),
                goal: String) {
        self.id = id; self.goal = goal; self.status = .running; self.createdAt = Date()
        self.finishedAt = nil; self.steps = []; self.events = []; self.finalAnswer = ""
        self.error = nil; self.toolCallCount = 0; self.modelCallCount = 0
    }

    public var durationMs: Double {
        (finishedAt ?? Date()).timeIntervalSince(createdAt) * 1000
    }

    public var reportJSON: [String: Any] {
        [
            "task_id": id,
            "goal": goal,
            "status": status.rawValue,
            "created_at": AgentTime.iso(createdAt),
            "finished_at": finishedAt.map { AgentTime.iso($0) } as Any,
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

public struct AgentPolicy: Codable, Hashable, Sendable {
    public var maxSteps: Int = 8
    public var maxToolCalls: Int = 16
    public var totalTimeout: TimeInterval = 150
    public var maxResultChars: Int = 6000
    public var retryNetworkOnce: Bool = true
    public init() {}
}

// MARK: - 小工具

public enum AgentTime {
    public static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}

public enum AgentJSON {
    public static func any(_ v: JSONValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n
        case .string(let s): return s
        case .array(let a): return a.map { any($0) }
        case .object(let o): return o.mapValues { any($0) }
        }
    }

    public static func encode(_ v: JSONValue) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: any(v), options: [.fragmentsAllowed]),
              let s = String(data: d, encoding: .utf8) else { return "null" }
        return s
    }

    public static func parse(_ data: Data) -> JSONValue? {
        guard let o = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue.from(any: o)
    }

    public static func parse(_ text: String) -> JSONValue? { parse(Data(text.utf8)) }

    /// 从任意文本里抽出第一个完整的 JSON 对象（模型常在 JSON 前后加说明文字）。
    public static func firstObject(in text: String) -> [String: JSONValue]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"),
              start <= end else { return nil }
        let slice = String(text[start...end])
        guard case .object(let o)? = parse(slice) else { return nil }
        return o
    }
}
