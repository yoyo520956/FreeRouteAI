import Foundation
import Observation

/// 统计中心数据（全部由请求日志推导，不造假）
@MainActor
@Observable
public final class StatisticsEngine {
    public private(set) var todayRequests: Int = 0
    public private(set) var todaySuccessRate: Double = 0
    public private(set) var todayTokens: Int = 0
    public private(set) var avgLatencyMs: Double = 0
    public private(set) var p95LatencyMs: Double = 0
    public private(set) var switchCount: Int = 0
    public var rangeDays: Int = 7 { didSet { reload() } }

    public private(set) var dailySeries: [DailyPoint] = []
    public private(set) var modelRanking: [RankItem] = []
    public private(set) var providerRanking: [RankItem] = []
    public private(set) var latencySeries: [LatencyPoint] = []
    public private(set) var errorHistogram: [ErrorBucket] = []
    public private(set) var hourlySeries: [HourlyPoint] = []

    public struct DailyPoint: Identifiable, Sendable {
        public var id: String { day }
        public var day: String          // MM-dd
        public var requests: Int
        public var success: Int
        public var tokens: Int
        public var successRate: Double
    }
    public struct RankItem: Identifiable, Sendable {
        public var id: String { name }
        public var name: String
        public var requests: Int
        public var tokens: Int
        public var successRate: Double
        public var avgLatencyMs: Double
    }
    public struct LatencyPoint: Identifiable, Sendable {
        public var id = UUID()
        public var time: Date
        public var ms: Double
    }
    public struct ErrorBucket: Identifiable, Sendable {
        public var id: Int { status }
        public var status: Int
        public var count: Int
    }
    public struct HourlyPoint: Identifiable, Sendable {
        public var id: Int { hour }
        public var hour: Int
        public var requests: Int
        public var tokens: Int
    }

    private weak var app: AppState?

    public init() {}

    public func bind(_ app: AppState) { self.app = app }

    public func reload() {
        guard let app else { return }
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        let from = cal.date(byAdding: .day, value: -(rangeDays - 1), to: todayStart) ?? todayStart
        let all = (try? app.store.fetchLogsBetween(from, now)) ?? []

        let today = all.filter { $0.timestamp >= todayStart }
        todayRequests = today.count
        todayTokens = today.reduce(0) { $0 + $1.totalTokens }
        let okToday = today.filter { $0.ok }.count
        todaySuccessRate = today.isEmpty ? 0 : Double(okToday) / Double(today.count)
        let durations = today.map { $0.durationMs }.filter { $0 > 0 }.sorted()
        avgLatencyMs = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)
        p95LatencyMs = durations.isEmpty ? 0 : durations[min(durations.count - 1, Int(Double(durations.count) * 0.95))]
        switchCount = today.filter { $0.switched }.count

        // 按天
        var daily: [String: (req: Int, ok: Int, tok: Int)] = [:]
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd"
        for l in all {
            let key = fmt.string(from: l.timestamp)
            var v = daily[key] ?? (0, 0, 0)
            v.req += 1
            if l.ok { v.ok += 1 }
            v.tok += l.totalTokens
            daily[key] = v
        }
        dailySeries = daily.keys.sorted().map { k in
            let v = daily[k] ?? (0, 0, 0)
            return DailyPoint(day: k, requests: v.req, success: v.ok, tokens: v.tok,
                              successRate: v.req == 0 ? 0 : Double(v.ok) / Double(v.req))
        }

        // 排行
        modelRanking = group(all, key: { $0.modelID })
        providerRanking = group(all, key: { $0.providerName })

        // 延迟散点（最近 200 条）
        latencySeries = all.suffix(200).map { LatencyPoint(time: $0.timestamp, ms: $0.durationMs) }

        // 错误直方图
        var buckets: [Int: Int] = [:]
        for l in all where !l.ok { buckets[l.httpStatus, default: 0] += 1 }
        errorHistogram = buckets.map { ErrorBucket(status: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        // 今日按小时
        var hourly: [Int: (Int, Int)] = [:]
        for l in today {
            let h = cal.component(.hour, from: l.timestamp)
            var v = hourly[h] ?? (0, 0)
            v.0 += 1; v.1 += l.totalTokens
            hourly[h] = v
        }
        hourlySeries = (0..<24).map { h in
            let v = hourly[h] ?? (0, 0)
            return HourlyPoint(hour: h, requests: v.0, tokens: v.1)
        }
    }

    private func group(_ logs: [DBRequestLog], key: (DBRequestLog) -> String) -> [RankItem] {
        var dict: [String: (req: Int, ok: Int, tok: Int, lat: Double)] = [:]
        for l in logs {
            let k = key(l)
            var v = dict[k] ?? (0, 0, 0, 0)
            v.req += 1
            if l.ok { v.ok += 1 }
            v.tok += l.totalTokens
            v.lat += l.durationMs
            dict[k] = v
        }
        return dict.map { (k, v) in
            RankItem(name: k.isEmpty ? "未知" : k, requests: v.req, tokens: v.tok,
                     successRate: v.req == 0 ? 0 : Double(v.ok) / Double(v.req),
                     avgLatencyMs: v.req == 0 ? 0 : v.lat / Double(v.req))
        }
        .sorted { $0.requests > $1.requests }
    }
}
