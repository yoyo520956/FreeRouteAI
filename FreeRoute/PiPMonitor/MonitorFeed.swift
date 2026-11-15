import Foundation
import Observation

/// 实时监控数据（供 PiP / 悬浮窗 / 实时监控页 / Live Activity 共用）
@MainActor
@Observable
public final class MonitorFeed {
    public private(set) var currentModel: String = "—"
    public private(set) var currentProvider: String = "—"
    public private(set) var sessionTokens: Int = 0
    public private(set) var tokensPerSecond: Double = 0
    public private(set) var lastRequestDurationMs: Double = 0
    public private(set) var activeRequests: Int = 0
    public private(set) var completedRequests: Int = 0
    public private(set) var failedRequests: Int = 0
    public private(set) var gatewayRunning: Bool = false
    public private(set) var lastEventText: String = "等待请求"
    public private(set) var isStreaming: Bool = false

    private var samples: [(time: Date, tokens: Int)] = []
    private var streamStartedAt: Date?
    private var requestStartedAt: Date?
    private var rollingWindow: TimeInterval = 10

    public init() {}

    public func markRequestStart(provider: String, model: String) {
        activeRequests += 1
        requestStartedAt = Date()
        currentProvider = provider
        currentModel = model
        isStreaming = true
        lastEventText = "请求中：\(model)"
    }

    public func addTokens(_ count: Int) {
        guard count > 0 else { return }
        sessionTokens += count
        let now = Date()
        samples.append((now, count))
        samples.removeAll { now.timeIntervalSince($0.time) > rollingWindow }
        let first = samples.first?.time ?? now
        let span = max(now.timeIntervalSince(first), 0.5)
        let total = samples.reduce(0) { $0 + $1.tokens }
        // 首包（span 过小）时用最近一个采样估算，避免出现无意义的巨大瞬时值
        tokensPerSecond = span < 1.0 ? Double(count) : Double(total) / span
        isStreaming = true
    }

    public func markRequestEnd(ok: Bool, durationMs: Double, errorNote: String? = nil) {
        activeRequests = max(0, activeRequests - 1)
        isStreaming = activeRequests > 0
        lastRequestDurationMs = durationMs
        if ok { completedRequests += 1 } else { failedRequests += 1 }
        lastEventText = ok ? "完成（\(Int(durationMs)) ms）" : "失败：\(errorNote ?? "未知错误")"
        streamStartedAt = nil
    }

    public func setGatewayRunning(_ running: Bool) {
        gatewayRunning = running
        if !running { tokensPerSecond = 0 }
    }

    public func resetSession() {
        sessionTokens = 0; tokensPerSecond = 0; samples.removeAll()
        completedRequests = 0; failedRequests = 0; activeRequests = 0
        lastEventText = "已重置"
    }

    /// “00:12”风格的请求时长文本（从最近一次请求开始计算，用于监控页底部）
    public func elapsedText(now: Date = Date()) -> String {
        guard let started = requestStartedAt else { return "0:00" }
        let s = Int(now.timeIntervalSince(started))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
