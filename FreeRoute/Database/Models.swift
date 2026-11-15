import Foundation
import SwiftData

// MARK: - JSON 文本辅助
// 注意：不能写 `try? encoder.encode(x).flatMap { String(data: $0, ...) }`——
// 那样 flatMap 落在 Data（Collection）上，$0 是 UInt8 而不是 Data，编译不过。

/// 编码为 JSON 文本，失败返回 nil
func jsonString<T: Encodable>(_ value: T) -> String? {
    guard let d = try? JSONEncoder().encode(value) else { return nil }
    return String(data: d, encoding: .utf8)
}

/// 任意 JSON 对象转文本（用于 [String: String] 这类不需要 Codable 容器的场景）
func jsonString(fromObject obj: Any) -> String? {
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return nil }
    return String(data: d, encoding: .utf8)
}

// MARK: - SwiftData 实体（持久层；Key 明文不入库）

@Model
public final class DBProvider {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var kindRaw: String
    public var protocolRaw: String
    public var baseURL: String
    public var requestPath: String?
    public var modelsPath: String?
    public var embeddingsPath: String?
    public var customHeadersJSON: String
    public var timeout: Double
    public var keysJSON: String
    public var enabled: Bool
    public var notes: String
    public var freeQuotaJSON: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(provider: Provider) {
        self.id = provider.id
        self.name = provider.name
        self.kindRaw = provider.kind.rawValue
        self.protocolRaw = provider.protocolType.rawValue
        self.baseURL = provider.baseURL
        self.requestPath = provider.requestPath
        self.modelsPath = provider.modelsPath
        self.embeddingsPath = provider.embeddingsPath
        self.customHeadersJSON = jsonString(fromObject: provider.customHeaders) ?? "{}"
        self.timeout = provider.timeout
        self.keysJSON = jsonString(provider.keys) ?? "[]"
        self.enabled = provider.enabled
        self.notes = provider.notes
        self.freeQuotaJSON = jsonString(AnyCodableQuota(value: provider.freeQuota))
        self.createdAt = Date()
        self.updatedAt = Date()
    }

    public var provider: Provider {
        var headers = [String: String]()
        if let d = customHeadersJSON.data(using: .utf8) {
            headers = (try? JSONSerialization.jsonObject(with: d) as? [String: String]) ?? [:]
        }
        var keys: [APIKeyRef] = []
        if let d = keysJSON.data(using: .utf8) {
            keys = (try? JSONDecoder().decode([APIKeyRef].self, from: d)) ?? []
        }
        var quota: FreeQuotaInfo?
        if let q = freeQuotaJSON, let d = q.data(using: .utf8) {
            quota = (try? JSONDecoder().decode(AnyCodableQuota.self, from: d))?.value
        }
        return Provider(
            id: id,
            kind: ProviderKind(rawValue: kindRaw) ?? .custom,
            name: name,
            protocolType: ProviderProtocolType(rawValue: protocolRaw) ?? .openaiCompatible,
            baseURL: baseURL,
            requestPath: requestPath,
            modelsPath: modelsPath,
            embeddingsPath: embeddingsPath,
            customHeaders: headers,
            timeout: timeout,
            keys: keys,
            enabled: enabled,
            notes: notes,
            freeQuota: quota
        )
    }
}

/// FreeQuotaInfo 可为空的包装（SwiftData 不便直接存 Optional 自定义 Codable 时用它）
public struct AnyCodableQuota: Codable {
    public var value: FreeQuotaInfo?
    public static let none = AnyCodableQuota(value: nil)
    public init(value: FreeQuotaInfo? = nil) { self.value = value }
}

@Model
public final class DBModel {
    @Attribute(.unique) public var id: String
    public var providerID: UUID
    public var providerName: String
    public var modelID: String
    public var displayName: String
    public var capabilitiesRaw: String
    public var contextLength: Int?
    public var maxOutputTokens: Int?
    public var inputPricePer1K: Double?
    public var outputPricePer1K: Double?
    public var isFreeTier: Bool
    public var healthRaw: String
    public var successRate: Double
    public var avgLatencyMs: Double?
    public var lastRefreshed: Date
    public var lastTested: Date?
    public var note: String

    public init(model: ModelInfo, capabilities: Set<ModelCapability> = Set<ModelCapability>()) {
        self.id = model.id
        self.providerID = model.providerID
        self.providerName = model.providerName
        self.modelID = model.modelID
        self.displayName = model.displayName
        self.capabilitiesRaw = capabilities.map(\.rawValue).joined(separator: ",")
        self.contextLength = model.contextLength
        self.maxOutputTokens = model.maxOutputTokens
        self.inputPricePer1K = model.inputPricePer1K
        self.outputPricePer1K = model.outputPricePer1K
        self.isFreeTier = model.isFreeTier
        self.healthRaw = model.health.rawValue
        self.successRate = model.successRate
        self.avgLatencyMs = model.avgLatencyMs
        self.lastRefreshed = model.lastRefreshed
        self.lastTested = model.lastTested
        self.note = model.note
    }

    public var modelInfo: ModelInfo {
        var caps = capabilitiesRaw.isEmpty ? [ModelCapability.text]
            : capabilitiesRaw.split(separator: ",").compactMap { ModelCapability(rawValue: String($0)) }
        return ModelInfo(
            providerID: providerID,
            providerName: providerName,
            modelID: modelID,
            displayName: displayName,
            capabilities: caps,
            contextLength: contextLength,
            maxOutputTokens: maxOutputTokens,
            inputPricePer1K: inputPricePer1K,
            outputPricePer1K: outputPricePer1K,
            isFreeTier: isFreeTier,
            health: ModelHealth(rawValue: healthRaw) ?? .unknown,
            successRate: successRate,
            avgLatencyMs: avgLatencyMs,
            lastRefreshed: lastRefreshed,
            lastTested: lastTested,
            note: note
        )
    }

    public var capabilitySet: Set<ModelCapability> {
        Set(modelInfo.capabilities)
    }
}

@Model
public final class DBRequestLog {
    public var id: UUID
    public var timestamp: Date
    public var modelID: String
    public var providerName: String
    public var durationMs: Double
    public var promptTokens: Int
    public var completionTokens: Int
    public var totalTokens: Int
    public var httpStatus: Int
    public var switched: Bool
    public var ok: Bool
    public var errorNote: String?

    public init(id: UUID = UUID(), timestamp: Date = Date(), modelID: String, providerName: String,
                durationMs: Double, promptTokens: Int = 0, completionTokens: Int = 0, totalTokens: Int = 0,
                httpStatus: Int = 0, switched: Bool = false, ok: Bool, errorNote: String? = nil) {
        self.id = id; self.timestamp = timestamp; self.modelID = modelID; self.providerName = providerName
        self.durationMs = durationMs; self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.totalTokens = totalTokens; self.httpStatus = httpStatus; self.switched = switched
        self.ok = ok; self.errorNote = errorNote
    }
}
