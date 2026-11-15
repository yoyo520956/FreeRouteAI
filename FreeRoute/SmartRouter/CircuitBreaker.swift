import Foundation

/// 熔断器：429 冷却 / 401 密钥失效 / 403 权限 / 5xx 指数退避
public final class CircuitBreaker: @unchecked Sendable {
    public enum State: String, Sendable { case closed, open, halfOpen }

    public struct Snapshot: Sendable {
        public var state: State
        public var failureCount: Int
        public var successCount: Int
        public var cooldownUntil: Date?
        public var lastError: String?

        public var isAvailable: Bool { state != .open || (cooldownUntil.map { $0 <= Date() } ?? true) }
        public var cooldownRemaining: TimeInterval {
            guard let until = cooldownUntil else { return 0 }
            return max(0, until.timeIntervalSince(Date()))
        }
    }

    private let lock = NSLock()
    private var snapshots: [String: Snapshot] = [:]
    public var maxConsecutiveFailures: Int = 4
    public var baseBackoff: TimeInterval = 5
    public var maxBackoff: TimeInterval = 600

    public init() {}

    public func snapshot(for key: String) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshots[key] ?? Snapshot(state: .closed, failureCount: 0, successCount: 0, cooldownUntil: nil, lastError: nil)
    }

    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(snapshots.keys)
    }

    public func reset(key: String) {
        lock.lock(); defer { lock.unlock() }
        snapshots[key] = nil
    }

    public func recordSuccess(key: String) {
        lock.lock(); defer { lock.unlock() }
        var s = snapshots[key] ?? Snapshot(state: .closed, failureCount: 0, successCount: 0, cooldownUntil: nil, lastError: nil)
        s.failureCount = 0
        s.successCount += 1
        s.state = .closed
        s.cooldownUntil = nil
        s.lastError = nil
        snapshots[key] = s
    }

    /// 记录失败，返回本次采用的冷却时长（秒）
    @discardableResult
    public func recordFailure(key: String, error: UpstreamError, retryAfter: TimeInterval? = nil) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        var s = snapshots[key] ?? Snapshot(state: .closed, failureCount: 0, successCount: 0, cooldownUntil: nil, lastError: nil)

        // 401/403 不是瞬时故障：长时间熔断（需人工换密钥）
        let longCooldown = error.isUnauthorized || error.isForbidden
        s.failureCount += 1
        s.lastError = error.errorDescription ?? "未知错误"

        let backoff: TimeInterval
        if longCooldown {
            backoff = 3600
            s.state = .open
        } else if let ra = retryAfter, ra > 0 {
            backoff = min(max(ra, 1), maxBackoff)
            s.state = .open
        } else if error.isRateLimited {
            backoff = min(baseBackoff * pow(2, Double(min(s.failureCount, 6))), maxBackoff)
            s.state = .open
        } else if error.isServerError || error.isRetryable {
            backoff = min(baseBackoff * pow(2, Double(min(s.failureCount, 6))), maxBackoff)
            s.state = s.failureCount >= maxConsecutiveFailures ? .open : .halfOpen
        } else {
            // 解析类错误：短暂熔断，避免打死同一上游
            backoff = min(baseBackoff, maxBackoff)
            s.state = s.failureCount >= maxConsecutiveFailures ? .open : .halfOpen
        }

        s.cooldownUntil = Date().addingTimeInterval(backoff)
        snapshots[key] = s
        return backoff
    }

    public func isAvailable(key: String) -> Bool {
        snapshot(for: key).isAvailable
    }

    public func cooldownRemaining(for key: String) -> TimeInterval {
        snapshot(for: key).cooldownRemaining
    }

    /// 供界面展示的简要状态
    public func displayState(for key: String) -> ModelHealth {
        let s = snapshot(for: key)
        if s.state == .open && s.cooldownRemaining > 0 { return .cooldown }
        if s.failureCount == 0 && s.successCount == 0 { return .unknown }
        if s.failureCount >= maxConsecutiveFailures { return .failing }
        if s.failureCount > 0 { return .degraded }
        return .healthy
    }
}

/// 指数退避重试策略（禁止无限重试）
public struct BackoffPolicy: Sendable {
    public var maxAttempts: Int
    public var baseDelay: TimeInterval
    public var maxDelay: TimeInterval
    public var jitter: Double

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.6, maxDelay: TimeInterval = 8, jitter: Double = 0.25) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitter = jitter
    }

    /// 第 attempt 次（从 0 开始）失败后的等待；超过上限返回 nil（不再重试）
    public func delay(afterAttempt attempt: Int) -> TimeInterval? {
        guard attempt + 1 < maxAttempts else { return nil }
        let raw = min(baseDelay * pow(2, Double(attempt)), maxDelay)
        let j = raw * jitter * Double.random(in: -1...1)
        return max(0.05, raw + j)
    }
}
