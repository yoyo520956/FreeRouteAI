import Foundation
import Observation

/// Smart Router：六维评分 + 熔断 + 故障切换（不在流式已输出后整段重放）
@MainActor
@Observable
public final class RouterEngine {
    public var mode: RouterMode
    public var weightsOverride: RouteWeights?
    public let breaker = CircuitBreaker()
    public var policy = BackoffPolicy(maxAttempts: 3)
    public private(set) var lastDecision: RouteDecision = .empty
    /// 每模型并发计数（负载维度）
    private var inFlight: [String: Int] = [:]
    public private(set) var totalSwitches: Int = 0

    public init(mode: RouterMode = .smartBalanced) {
        self.mode = mode
    }

    public var activeWeights: RouteWeights { (weightsOverride ?? mode.weights).normalized }

    // MARK: 负载

    public func beginUse(_ candidate: RouteCandidate) { inFlight[candidate.id, default: 0] += 1 }
    public func endUse(_ candidate: RouteCandidate) { inFlight[candidate.id, default: 0] = max(0, (inFlight[candidate.id] ?? 1) - 1) }
    public func load(for id: String) -> Int { inFlight[id] ?? 0 }

    // MARK: 健康记录

    public func recordSuccess(model: ModelInfo, keyRef: String) {
        breaker.recordSuccess(key: breakerKey(model: model, keyRef: keyRef))
    }

    @discardableResult
    public func recordFailure(model: ModelInfo, keyRef: String, error: UpstreamError, retryAfter: TimeInterval? = nil) -> TimeInterval {
        breaker.recordFailure(key: breakerKey(model: model, keyRef: keyRef), error: error, retryAfter: retryAfter)
    }

    private func breakerKey(model: ModelInfo, keyRef: String) -> String {
        model.providerID.uuidString + "|" + keyRef + "|" + model.modelID
    }

    // MARK: 评分

    public func rank(candidates: [RouteCandidate], request: ChatRequest?) -> [RouteScore] {
        let w = activeWeights
        let fastest = candidates.compactMap { $0.model.avgLatencyMs }.filter { $0 > 0 }.min() ?? 300

        var scores: [RouteScore] = []
        for c in candidates {
            var blocked = false
            var blockReason: String?

            if !c.provider.enabled { blocked = true; blockReason = "服务商已停用" }
            else if !c.hasUsableKey { blocked = true; blockReason = "没有可用密钥" }
            else {
                let bk = breakerKey(model: c.model, keyRef: c.provider.keys.first?.keychainRef ?? "-")
                let rem = breaker.cooldownRemaining(for: bk)
                if rem > 0 { blocked = true; blockReason = String(format: "熔断冷却中（剩 %.0fs）", rem) }
            }

            // 能力匹配（硬性）
            var capabilityRaw = 1.0
            if let request {
                let needed = neededCapabilities(of: request)
                let have = c.model.capabilitySet
                if !needed.isSubset(of: have) {
                    capabilityRaw = 0.2
                }
            }

            let healthRaw = c.model.health.healthScore
            let freeRaw = c.model.isFreeTier ? 1.0 : 0.25
            let successRaw = max(0, min(1, c.model.successRate))
            let lat = c.model.avgLatencyMs ?? (fastest * 2)
            let latencyRaw = lat > 0 ? max(0.05, min(1.0, fastest / max(lat, fastest))) : 0.5
            let loadCount = load(for: c.id)
            let loadRaw = max(0.0, 1.0 - Double(loadCount) * 0.34)

            let parts: [(name: String, raw: Double, weighted: Double)] = [
                ("健康状态", healthRaw, healthRaw * w.health),
                ("免费额度", freeRaw, freeRaw * w.freeQuota),
                ("历史成功率", successRaw, successRaw * w.successRate),
                ("响应延迟", latencyRaw, latencyRaw * w.latency),
                ("当前负载", loadRaw, loadRaw * w.load),
                ("能力匹配", capabilityRaw, capabilityRaw * w.capability)
            ]
            var score = parts.reduce(0) { $0 + $1.weighted }
            if blocked { score = -1 }

            let best = parts.max(by: { $0.weighted < $1.weighted })?.name ?? "综合"
            let reason: String
            if let br = blockReason {
                reason = br
            } else {
                let lat = c.model.avgLatencyMs
                reason = String(format: "得分 %.3f，主要来源：%@%@%@", score, best,
                                c.model.isFreeTier ? "，免费额度" : "，付费",
                                lat.map { String(format: "，历史 %.0fms", $0) } ?? "")
            }
            scores.append(RouteScore(candidate: c, score: score, parts: parts, reason: reason,
                                     blocked: blocked, blockReason: blockReason))
        }
        return scores.sorted { $0.score > $1.score }
    }

    /// 依据请求推断必需能力
    public func neededCapabilities(of request: ChatRequest) -> Set<ModelCapability> {
        var needs: Set<ModelCapability> = [.text]
        if request.toolsJSON != nil { needs.insert(.functionCalling) }
        if request.responseFormatJSON != nil { needs.insert(.structuredOutput) }
        return needs
    }

    public func decide(candidates: [RouteCandidate], request: ChatRequest?) -> RouteDecision {
        let ranked = rank(candidates: candidates, request: request)
        let chosen = ranked.first(where: { !$0.blocked })
        let reason: String
        if let c = chosen {
            reason = "\(mode.rawValue) 选择 \(c.candidate.model.displayName)（\(c.candidate.provider.name)）：\(c.reason)"
        } else if let first = ranked.first {
            reason = "无可用候选：\(first.blockReason ?? "全部熔断")"
        } else {
            reason = "没有可用模型，请先添加服务商或刷新模型"
        }
        lastDecision = RouteDecision(chosen: chosen?.candidate, ranked: ranked, mode: mode, reason: reason)
        return lastDecision
    }

    /// 供界面展示排名（不改变 lastDecision 的语义可另调用 decide）
    public func preview(candidates: [RouteCandidate], request: ChatRequest? = nil) -> [RouteScore] {
        rank(candidates: candidates, request: request)
    }

    public func noteSwitch() { totalSwitches += 1 }
}
