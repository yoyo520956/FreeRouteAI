import Foundation

// MARK: - 路由模式

public enum RouterMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case smartFree = "SMART FREE"
    case smartFast = "SMART FAST"
    case smartReliable = "SMART RELIABLE"
    case smartBalanced = "SMART BALANCED"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .smartFree: return "智能免费"
        case .smartFast: return "智能极速"
        case .smartReliable: return "智能稳定"
        case .smartBalanced: return "智能均衡"
        }
    }

    public var detail: String {
        switch self {
        case .smartFree: return "优先消耗免费额度，尽量不动用付费模型"
        case .smartFast: return "优先历史低延迟与高吞吐（tok/s）"
        case .smartReliable: return "优先健康度与历史成功率，抗故障"
        case .smartBalanced: return "六维均衡，日常默认"
        }
    }

    /// 需求规定的默认权重：健康25 / 免费20 / 成功率20 / 延迟15 / 负载10 / 能力10
    public static let defaultWeights = RouteWeights(health: 0.25, freeQuota: 0.20, successRate: 0.20,
                                                    latency: 0.15, load: 0.10, capability: 0.10)

    public var weights: RouteWeights {
        switch self {
        case .smartFree:
            return RouteWeights(health: 0.20, freeQuota: 0.40, successRate: 0.15, latency: 0.10, load: 0.05, capability: 0.10)
        case .smartFast:
            return RouteWeights(health: 0.15, freeQuota: 0.05, successRate: 0.15, latency: 0.50, load: 0.05, capability: 0.10)
        case .smartReliable:
            return RouteWeights(health: 0.40, freeQuota: 0.05, successRate: 0.35, latency: 0.05, load: 0.05, capability: 0.10)
        case .smartBalanced:
            return Self.defaultWeights
        }
    }
}

/// 六维权重（界面可调，内部自动归一化）
public struct RouteWeights: Codable, Hashable, Sendable {
    public var health: Double
    public var freeQuota: Double
    public var successRate: Double
    public var latency: Double
    public var load: Double
    public var capability: Double

    public init(health: Double, freeQuota: Double, successRate: Double, latency: Double, load: Double, capability: Double) {
        self.health = health; self.freeQuota = freeQuota; self.successRate = successRate
        self.latency = latency; self.load = load; self.capability = capability
    }

    public var sum: Double { health + freeQuota + successRate + latency + load + capability }

    public var normalized: RouteWeights {
        let s = sum
        guard s > 0 else { return RouterMode.defaultWeights }
        return RouteWeights(health: health / s, freeQuota: freeQuota / s, successRate: successRate / s,
                            latency: latency / s, load: load / s, capability: capability / s)
    }

    public subscript(key: String) -> Double {
        switch key {
        case "健康状态": return health
        case "免费额度": return freeQuota
        case "历史成功率": return successRate
        case "响应延迟": return latency
        case "当前负载": return load
        case "能力匹配": return capability
        default: return 0
        }
    }

    public var breakdownLines: [(name: String, value: Double)] {
        [("健康状态", health), ("免费额度", freeQuota), ("历史成功率", successRate),
         ("响应延迟", latency), ("当前负载", load), ("能力匹配", capability)]
    }
}

// MARK: - 评分与决策

public struct RouteScore: Identifiable, Sendable {
    public var id: String { candidate.id }
    public var candidate: RouteCandidate
    public var score: Double
    public var parts: [(name: String, raw: Double, weighted: Double)]
    public var reason: String
    public var blocked: Bool
    public var blockReason: String?

    public init(candidate: RouteCandidate, score: Double, parts: [(name: String, raw: Double, weighted: Double)],
                reason: String, blocked: Bool = false, blockReason: String? = nil) {
        self.candidate = candidate; self.score = score; self.parts = parts; self.reason = reason
        self.blocked = blocked; self.blockReason = blockReason
    }
}

/// 候选 = 模型 + 所属服务商（含可用密钥状态）
public struct RouteCandidate: Identifiable, Sendable {
    public var id: String { model.id }
    public var model: ModelInfo
    public var provider: Provider
    public var hasUsableKey: Bool

    public init(model: ModelInfo, provider: Provider, hasUsableKey: Bool) {
        self.model = model; self.provider = provider; self.hasUsableKey = hasUsableKey
    }
}

public struct RouteDecision: Sendable {
    public var chosen: RouteCandidate?
    public var ranked: [RouteScore]
    public var mode: RouterMode
    public var reason: String

    public init(chosen: RouteCandidate?, ranked: [RouteScore], mode: RouterMode, reason: String) {
        self.chosen = chosen; self.ranked = ranked; self.mode = mode; self.reason = reason
    }

    public static let empty = RouteDecision(chosen: nil, ranked: [], mode: .smartBalanced, reason: "没有可用候选")
}
