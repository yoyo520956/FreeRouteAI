import XCTest
@testable import FreeRoute

/// Smart Router 六维评分与决策
@MainActor
final class RouterScoringTests: XCTestCase {
    private func provider(name: String, free: Bool = true, key: Bool = true) -> Provider {
        Provider(kind: .custom, name: name, protocolType: .openaiCompatible,
                 baseURL: "https://example.invalid/v1",
                 keys: key ? [APIKeyRef(label: "k", keychainRef: "test/" + name)] : [],
                 freeQuota: free ? FreeQuotaInfo(hasFreeTier: true) : nil)
    }

    private func candidate(providerName: String, modelID: String, free: Bool, latency: Double?,
                           health: ModelHealth, success: Double, key: Bool = true,
                           caps: [ModelCapability] = [.text]) -> RouteCandidate {
        let p = provider(name: providerName, free: free, key: key)
        let m = ModelInfo(providerID: p.id, providerName: p.name, modelID: modelID,
                          capabilities: caps, isFreeTier: free, health: health,
                          successRate: success, avgLatencyMs: latency)
        return RouteCandidate(model: m, provider: p, hasUsableKey: key)
    }

    func testSmartFreePrefersFreeModel() {
        let engine = RouterEngine(mode: .smartFree)
        let paid = candidate(providerName: "付费源", modelID: "paid-1", free: false,
                             latency: 100, health: .healthy, success: 0.9)
        let free = candidate(providerName: "免费源", modelID: "free-1", free: true,
                             latency: 400, health: .healthy, success: 0.9)
        let ranked = engine.rank(candidates: [paid, free], request: nil)
        XCTAssertEqual(ranked.first?.candidate.model.modelID, "free-1",
                       "SMART FREE 应优先免费模型")
    }

    func testSmartFastPrefersLowLatency() {
        let engine = RouterEngine(mode: .smartFast)
        let slow = candidate(providerName: "慢但免费", modelID: "slow-free", free: true,
                             latency: 3000, health: .healthy, success: 0.9)
        let fast = candidate(providerName: "快但付费", modelID: "fast-paid", free: false,
                             latency: 120, health: .healthy, success: 0.9)
        let ranked = engine.rank(candidates: [slow, fast], request: nil)
        XCTAssertEqual(ranked.first?.candidate.model.modelID, "fast-paid",
                       "SMART FAST 应优先低延迟")
    }

    func testReliablePrefersHealthAndSuccess() {
        let engine = RouterEngine(mode: .smartReliable)
        let risky = candidate(providerName: "免费不稳定", modelID: "risky", free: true,
                              latency: 200, health: .degraded, success: 0.2)
        let solid = candidate(providerName: "付费稳定", modelID: "solid", free: false,
                              latency: 260, health: .healthy, success: 0.99)
        let ranked = engine.rank(candidates: [risky, solid], request: nil)
        XCTAssertEqual(ranked.first?.candidate.model.modelID, "solid")
    }

    func testNoKeyIsBlocked() {
        let engine = RouterEngine(mode: .smartBalanced)
        let noKey = candidate(providerName: "无密钥", modelID: "nokey", free: true,
                              latency: 100, health: .healthy, success: 1.0, key: false)
        let ranked = engine.rank(candidates: [noKey], request: nil)
        XCTAssertTrue(ranked.first?.blocked == true)
        let decision = engine.decide(candidates: [noKey], request: nil)
        XCTAssertNil(decision.chosen)
    }

    func testFunctionCallingRequirementLowersScore() {
        let engine = RouterEngine(mode: .smartBalanced)
        let noTools = candidate(providerName: "无工具", modelID: "plain", free: true,
                                latency: 150, health: .healthy, success: 0.9)
        let withTools = candidate(providerName: "支持工具", modelID: "tool-capable", free: true,
                                  latency: 150, health: .healthy, success: 0.9,
                                  caps: [.text, .functionCalling])
        var req = ChatRequest(model: "x", messages: [ChatMessage(role: .user, content: "hi")])
        req.toolsJSON = "[{\"type\":\"function\"}]"
        let ranked = engine.rank(candidates: [noTools, withTools], request: req)
        XCTAssertEqual(ranked.first?.candidate.model.modelID, "tool-capable",
                       "需要函数调用时应优先具备能力的模型")
    }

    func testWeightsNormalize() {
        let w = RouteWeights(health: 2, freeQuota: 2, successRate: 2, latency: 2, load: 2, capability: 2)
        let n = w.normalized
        XCTAssertEqual(n.health, 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(n.sum, 1.0, accuracy: 0.0001)
    }

    func testAllModeWeightsSumToOneAfterNormalize() {
        for mode in RouterMode.allCases {
            let n = mode.weights.normalized
            XCTAssertEqual(n.sum, 1.0, accuracy: 0.001, "\(mode.rawValue) 权重未归一")
        }
    }

    func testDefaultWeightsMatchRequirement() {
        let w = RouterMode.defaultWeights
        XCTAssertEqual(w.health, 0.25, accuracy: 0.0001)
        XCTAssertEqual(w.freeQuota, 0.20, accuracy: 0.0001)
        XCTAssertEqual(w.successRate, 0.20, accuracy: 0.0001)
        XCTAssertEqual(w.latency, 0.15, accuracy: 0.0001)
        XCTAssertEqual(w.load, 0.10, accuracy: 0.0001)
        XCTAssertEqual(w.capability, 0.10, accuracy: 0.0001)
    }
}
