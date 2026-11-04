import Foundation
import SwiftData

/// 数据库门面：实体增删查与统计查询
public final class ModelStore {
    private let container: ModelContainer

    public var context: ModelContext { container.mainContext }

    public init(container: ModelContainer) {
        self.container = container
        container.mainContext.autosaveEnabled = true
    }

    // MARK: Provider

    public func fetchProviders() throws -> [Provider] {
        let desc = FetchDescriptor<DBProvider>()
        return try context.fetch(desc).map { $0.provider }
    }

    @discardableResult
    public func saveProvider(_ p: Provider) throws -> DBProvider {
        let id = p.id
        var desc = FetchDescriptor<DBProvider>(predicate: #Predicate { $0.id == id })
        desc.fetchLimit = 1
        if let existing = try context.fetch(desc).first {
            if let d = try? JSONEncoder().encode(p.keys), let s = String(data: d, encoding: .utf8) { existing.keysJSON = s
 }
            existing.freeQuotaJSON = (try? JSONEncoder().encode(quota(p))).flatMap { String(data: $0, encoding: .utf8) }
            existing.name = p.name
            existing.baseURL = p.baseURL
            existing.protocolRaw = p.protocolType.rawValue
            existing.kindRaw = p.kind.rawValue
            existing.requestPath = p.requestPath
            existing.modelsPath = p.modelsPath
            existing.embeddingsPath = p.embeddingsPath
            existing.timeout = p.timeout
            existing.enabled = p.enabled
            existing.notes = p.notes
            if let d = try? JSONSerialization.data(withJSONObject: p.customHeaders), let s = String(data: d, encoding: .utf8) {
                existing.customHeadersJSON = s
            }
            existing.updatedAt = Date()
            return existing
        }
        let row = DBProvider(provider: p)
        context.insert(row)
        return row
    }

    public func deleteProvider(id: UUID) throws {
        let id2 = id
        var desc = FetchDescriptor<DBModel>(predicate: #Predicate { $0.providerID == id2 })
        for m in try context.fetch(desc) { context.delete(m) }
        var pdesc = FetchDescriptor<DBProvider>(predicate: #Predicate { $0.id == id2 })
        for p in try context.fetch(pdesc) { context.delete(p) }
    }

    private func quota(_ p: Provider) -> FreeQuotaInfo {
        p.freeQuota ?? FreeQuotaInfo(hasFreeTier: false, quotaNote: "未登记", rateLimitNote: "未登记",
                                     regionNote: "未登记", registrationNote: "未登记", accountNote: "未登记",
                                     freeModelsNote: "未登记", lastVerifiedISO: "")
    }

    // MARK: Model

    public func fetchModels() throws -> [ModelInfo] {
        let desc = FetchDescriptor<DBModel>()
        return try context.fetch(desc).map { $0.modelInfo }
    }

    public func upsertModels(_ models: [ModelInfo], for provider: Provider, capabilities: Set<ModelCapability> = []) throws {
        let existingDesc = FetchDescriptor<DBModel>()
        var byID: [String: DBModel] = Dictionary(uniqueKeysWithValues: try context.fetch(existingDesc).map { ($0.id, $0) })
        for m in models {
            if let row = byID[m.id] {
                row.displayName = m.displayName
                row.lastRefreshed = m.lastRefreshed
                row.contextLength = m.contextLength ?? row.contextLength
                row.isFreeTier = m.isFreeTier
                row.note = m.note
                row.healthRaw = m.health.rawValue
            } else {
                let row = DBModel(model: m, capabilities: capabilities)
                context.insert(row)
                byID[m.id] = row
            }
        }
    }

    // MARK: RequestLog

    @discardableResult
    public func appendLog(_ log: DBRequestLog) throws -> DBRequestLog {
        context.insert(log)
        return log
    }

    public func fetchLogs(limit: Int = 200, since: Date? = nil) throws -> [DBRequestLog] {
        var desc = FetchDescriptor<DBRequestLog>()
        desc.fetchLimit = limit
        if let since {
            desc.predicate = #Predicate<DBRequestLog> { $0.timestamp >= since }
            desc.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
        } else {
            desc.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
        }
        return try context.fetch(desc)
    }

    public func fetchLogsBetween(_ from: Date, _ to: Date) throws -> [DBRequestLog] {
        let desc = FetchDescriptor<DBRequestLog>(predicate: #Predicate<DBRequestLog> {
            $0.timestamp >= from && $0.timestamp <= to
        })
        return try context.fetch(desc)
    }

    /// 统计清理：删除 retentionDays 之前的日志
    public func pruneLogs(olderThan days: Int) throws {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        let desc = FetchDescriptor<DBRequestLog>(predicate: #Predicate<DBRequestLog> { $0.timestamp < cutoff })
        for l in try context.fetch(desc) { context.delete(l) }
    }
}
