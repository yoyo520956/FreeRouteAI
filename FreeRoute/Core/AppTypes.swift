import Foundation

// MARK: - 服务商类型

/// 内置服务商标识（对应 ProtocolAdapters 的具体实现）
public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openrouter, gemini, anthropic, groq, cerebras, cloudflare, nvidia, huggingface, ollama, openai, custom
    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openrouter:  return "OpenRouter"
        case .gemini:      return "Google Gemini"
        case .anthropic:   return "Anthropic"
        case .groq:        return "Groq"
        case .cerebras:    return "Cerebras"
        case .cloudflare:  return "Cloudflare Workers AI"
        case .nvidia:      return "NVIDIA NIM"
        case .huggingface: return "Hugging Face"
        case .ollama:      return "Ollama（本地）"
        case .openai:      return "OpenAI 兼容"
        case .custom:      return "自定义"
        }
    }
}

/// 上游协议族（决定用哪个 Adapter）
public enum ProviderProtocolType: String, Codable, CaseIterable, Sendable {
    case openaiCompatible, gemini, anthropic, ollama

    public var displayName: String {
        switch self {
        case .openaiCompatible: return "OpenAI 兼容"
        case .gemini:           return "Gemini REST"
        case .anthropic:        return "Anthropic Messages"
        case .ollama:          return "Ollama"
        }
    }

    /// 协议层面是否有官方模型目录接口。
    /// 四种协议都有（OpenAI 兼容 = GET /models，Gemini = GET /v1beta/models，
    /// Anthropic = GET /v1/models，Ollama = GET /api/tags），
    /// 但"某个具体服务商能不能列出厂"还取决于用户配置，见 Provider.supportsModelDiscovery。
    public var supportsModelList: Bool { true }
    public var supportsStreaming: Bool { true }
    public var supportsEmbeddings: Bool { self == .openaiCompatible }

    /// 模型目录接口的默认路径（供界面提示用户）
    public var defaultModelsEndpoint: String {
        switch self {
        case .openaiCompatible: return "GET /models"
        case .gemini:           return "GET /v1beta/models"
        case .anthropic:        return "GET /v1/models"
        case .ollama:           return "GET /api/tags"
        }
    }
}

// MARK: - API Key（只存引用，真实值在 Keychain）

public enum KeyStatus: String, Codable, Sendable, CaseIterable {
    case unknown, healthy, unauthorized, forbidden, rateLimited, disabled
    public var label: String {
        switch self {
        case .unknown: return "未测试"
        case .healthy: return "正常"
        case .unauthorized: return "密钥失效(401)"
        case .forbidden: return "无权限(403)"
        case .rateLimited: return "限流(429)"
        case .disabled: return "已禁用"
        }
    }
}

public struct APIKeyRef: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var keychainRef: String   // Keychain 存储键（数据库不存明文）
    public var status: KeyStatus
    public var lastUsed: Date?
    public var lastError: String?

    public init(id: UUID = UUID(), label: String = "默认密钥", keychainRef: String, status: KeyStatus = .unknown, lastUsed: Date? = nil, lastError: String? = nil) {
        self.id = id; self.label = label; self.keychainRef = keychainRef
        self.status = status; self.lastUsed = lastUsed; self.lastError = lastError
    }
}

// MARK: - 服务商配置

public struct FreeQuotaInfo: Codable, Hashable, Sendable {
    public var hasFreeTier: Bool
    public var quotaNote: String
    public var rateLimitNote: String
    public var regionNote: String
    public var registrationNote: String
    public var accountNote: String
    public var freeModelsNote: String
    public var lastVerifiedISO: String

    public init(hasFreeTier: Bool = true, quotaNote: String = "", rateLimitNote: String = "",
                regionNote: String = "", registrationNote: String = "", accountNote: String = "",
                freeModelsNote: String = "", lastVerifiedISO: String = "") {
        self.hasFreeTier = hasFreeTier; self.quotaNote = quotaNote; self.rateLimitNote = rateLimitNote
        self.regionNote = regionNote; self.registrationNote = registrationNote; self.accountNote = accountNote
        self.freeModelsNote = freeModelsNote; self.lastVerifiedISO = lastVerifiedISO
    }
}

public struct Provider: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: ProviderKind
    public var name: String
    public var protocolType: ProviderProtocolType
    public var baseURL: String
    public var requestPath: String?      // chat/completions 相对路径
    public var modelsPath: String?       // 模型列表相对路径
    public var embeddingsPath: String?   // embeddings 相对路径
    public var customHeaders: [String: String]
    public var timeout: TimeInterval
    public var keys: [APIKeyRef]
    public var enabled: Bool
    public var notes: String
    public var freeQuota: FreeQuotaInfo?

    public init(id: UUID = UUID(), kind: ProviderKind, name: String, protocolType: ProviderProtocolType,
                baseURL: String, requestPath: String? = nil, modelsPath: String? = nil,
                embeddingsPath: String? = nil, customHeaders: [String: String] = [:],
                timeout: TimeInterval = 60, keys: [APIKeyRef] = [], enabled: Bool = true,
                notes: String = "", freeQuota: FreeQuotaInfo? = nil) {
        self.id = id; self.kind = kind; self.name = name; self.protocolType = protocolType
        self.baseURL = baseURL; self.requestPath = requestPath; self.modelsPath = modelsPath
        self.embeddingsPath = embeddingsPath; self.customHeaders = customHeaders
        self.timeout = timeout; self.keys = keys; self.enabled = enabled
        self.notes = notes; self.freeQuota = freeQuota
    }

    /// 该服务商至少有一个未被禁用的密钥
    public var hasUsableKey: Bool {
        keys.contains { $0.status == .healthy || $0.status == .unknown || $0.status == .rateLimited }
    }

    /// 是否支持动态发现模型目录。
    /// 四种协议官方都有模型列表接口，但自建/代理服务可能没有：
    /// 用户把「模型列表路径」显式设为空串即表示"该服务商不支持动态发现"，界面会如实显示。
    public var supportsModelDiscovery: Bool {
        guard protocolType.supportsModelList else { return false }
        if let path = modelsPath, path.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return true
    }
}

// MARK: - 模型能力与健康

public enum ModelCapability: String, Codable, CaseIterable, Sendable {
    case text, image, audio, embeddings, rerank, functionCalling, structuredOutput, vision, audioOutput
    public var label: String {
        switch self {
        case .text: return "文本"
        case .image: return "图像生成"
        case .audio: return "语音"
        case .embeddings: return "向量"
        case .rerank: return "重排"
        case .functionCalling: return "函数调用"
        case .structuredOutput: return "结构化输出"
        case .vision: return "视觉输入"
        case .audioOutput: return "语音输出"
        }
    }
}

public enum ModelHealth: String, Codable, Sendable {
    case unknown, healthy, degraded, failing, cooldown
    public var label: String {
        switch self {
        case .unknown: return "未检测"
        case .healthy: return "正常"
        case .degraded: return "降级"
        case .failing: return "故障"
        case .cooldown: return "冷却中"
        }
    }
    /// 路由器健康维度得分 0...1
    public var healthScore: Double {
        switch self {
        case .unknown: return 0.6
        case .healthy: return 1.0
        case .degraded: return 0.5
        case .failing: return 0.05
        case .cooldown: return 0.2
        }
    }
}

public struct ModelInfo: Identifiable, Codable, Hashable, Sendable {
    /// 复合 ID："<providerUUID>/<modelID>"
    public var id: String
    public var providerID: UUID
    public var providerName: String
    public var modelID: String
    public var displayName: String
    public var capabilities: [ModelCapability]
    public var contextLength: Int?
    public var maxOutputTokens: Int?
    public var inputPricePer1K: Double?
    public var outputPricePer1K: Double?
    public var isFreeTier: Bool
    public var health: ModelHealth
    public var successRate: Double     // 0...1 滚动统计
    public var avgLatencyMs: Double?
    public var lastRefreshed: Date
    public var lastTested: Date?
    public var note: String

    public init(providerID: UUID, providerName: String, modelID: String, displayName: String = "",
                capabilities: [ModelCapability] = [.text], contextLength: Int? = nil,
                maxOutputTokens: Int? = nil, inputPricePer1K: Double? = nil, outputPricePer1K: Double? = nil,
                isFreeTier: Bool = false, health: ModelHealth = .unknown, successRate: Double = 0,
                avgLatencyMs: Double? = nil, lastRefreshed: Date = .distantPast, lastTested: Date? = nil,
                note: String = "") {
        self.id = providerID.uuidString + "/" + modelID
        self.providerID = providerID; self.providerName = providerName; self.modelID = modelID
        self.displayName = displayName.isEmpty ? modelID : displayName
        self.capabilities = capabilities; self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens; self.inputPricePer1K = inputPricePer1K
        self.outputPricePer1K = outputPricePer1K; self.isFreeTier = isFreeTier
        self.health = health; self.successRate = successRate; self.avgLatencyMs = avgLatencyMs
        self.lastRefreshed = lastRefreshed; self.lastTested = lastTested; self.note = note
    }

    public var capabilitySet: Set<ModelCapability> { Set(capabilities) }
}

// MARK: - 模型目录发现

public struct DiscoveredModel: Codable, Hashable, Sendable {
    public var modelID: String
    public var displayName: String?
    public var contextLength: Int?
    public var maxOutputTokens: Int?
    public var capabilities: [ModelCapability]
    public var isFreeTier: Bool
    public var inputPricePer1K: Double?
    public var outputPricePer1K: Double?
    public var note: String

    public init(modelID: String, displayName: String? = nil, contextLength: Int? = nil,
                maxOutputTokens: Int? = nil, capabilities: [ModelCapability] = [.text],
                isFreeTier: Bool = false, inputPricePer1K: Double? = nil, outputPricePer1K: Double? = nil,
                note: String = "") {
        self.modelID = modelID; self.displayName = displayName; self.contextLength = contextLength
        self.maxOutputTokens = maxOutputTokens; self.capabilities = capabilities
        self.isFreeTier = isFreeTier; self.inputPricePer1K = inputPricePer1K
        self.outputPricePer1K = outputPricePer1K; self.note = note
    }
}

public struct ProbeResult: Codable, Hashable, Sendable {
    public var ok: Bool
    public var latencyMs: Double
    public var message: String
    public var httpStatus: Int?

    public init(ok: Bool, latencyMs: Double, message: String = "", httpStatus: Int? = nil) {
        self.ok = ok; self.latencyMs = latencyMs; self.message = message; self.httpStatus = httpStatus
    }
}

// MARK: - 上游错误（带状态码语义，供 Router 决策）

public enum UpstreamError: LocalizedError, Sendable {
    case network(String)
    case timeout
    case decoding(String)
    case http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .network(let m): return "网络错误：\(m)"
        case .timeout:        return "请求超时"
        case .decoding(let m): return "响应解析失败：\(m)"
        case .http(let s, let m): return "上游 HTTP \(s)：\(m)"
        }
    }

    public var status: Int? {
        switch self {
        case .http(let s, _): return s
        default: return nil
        }
    }

    public var isUnauthorized: Bool { self.status == 401 }
    public var isForbidden: Bool { self.status == 403 }
    public var isRateLimited: Bool { self.status == 429 }
    public var isServerError: Bool {
        switch self {
        case .http(let s, _): return (500..<600).contains(s)
        default: return false
        }
    }
    /// 网络/超时/5xx 可重试；401/403 应禁用密钥
    public var isRetryable: Bool {
        switch self {
        case .network, .timeout: return true
        case .http(let s, _): return (500...599).contains(s) || s == 429 || s == 408 || s == 503
        case .decoding: return false
        }
    }
}

public enum AppError: LocalizedError, Sendable {
    case noKeychain, keyNotFound(String), noEnabledProvider, noModel, cancel, unsupported(String)
    public var errorDescription: String? {
        switch self {
        case .noKeychain: return "无法访问钥匙串"
        case .keyNotFound(let k): return "未找到密钥引用：\(k)"
        case .noEnabledProvider: return "没有已启用的服务商"
        case .noModel: return "没有可用模型"
        case .cancel: return "已取消"
        case .unsupported(let m): return "暂不支持：\(m)"
        }
    }
}
