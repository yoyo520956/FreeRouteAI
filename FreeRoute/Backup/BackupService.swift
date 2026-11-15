import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// 备份：配置 + 模型 + 日志 → JSON（可选 AES-GCM 加密；默认不含明文 Key）
public struct BackupService: Sendable {
    public init() {}

    public struct Snapshot: Codable {
        public var version: Int = 1
        public var exportedAt: Date = Date()
        public var app: String = "FreeRoute AI"
        public var settings: AppSettings
        public var providers: [Provider]
        public var models: [ModelInfo]
        public var logs: [LogDTO]
        public var keysIncluded: Bool
    }

    public struct LogDTO: Codable {
        public var timestamp: Date
        public var modelID: String
        public var providerName: String
        public var durationMs: Double
        public var totalTokens: Int
        public var httpStatus: Int
        public var switched: Bool
        public var ok: Bool
        public var errorNote: String?
    }

    public struct ImportReport: Sendable {
        public var providers: Int
        public var models: Int
        public var logs: Int
        public var message: String
    }

    public enum BackupError: LocalizedError {
        case encodeFailed(String), decodeFailed(String), wrongFormat, decryptFailed
        public var errorDescription: String? {
            switch self {
            case .encodeFailed(let s): return "导出失败：\(s)"
            case .decodeFailed(let s): return "导入失败：\(s)"
            case .wrongFormat: return "不是 FreeRoute 备份文件"
            case .decryptFailed: return "解密失败：口令错误或文件已损坏"
            }
        }
    }

    /// 生成备份数据（默认 includeKeys=false，绝不含明文 Key）
    public func makeSnapshot(providers: [Provider], models: [ModelInfo], logs: [DBRequestLog],
                             settings: AppSettings, includeKeys: Bool, keyReader: (String) -> String?) throws -> Data {
        let sanitized: [Provider] = providers.map { p in
            var copy = p
            if includeKeys {
                copy.keys = p.keys.map { ref in
                    var r = ref
                    r.label = (keyReader(ref.keychainRef) ?? "").isEmpty ? ref.label : ref.label + "（含明文）"
                    return r
                }
            } else {
                copy.keys = p.keys.map { ref in
                    var r = ref
                    r.label = KeychainStore.mask(keyReader(ref.keychainRef) ?? "")
                    return r
                }
            }
            return copy
        }
        let snapshot = Snapshot(
            settings: settings,
            providers: sanitized,
            models: models,
            logs: logs.map {
                LogDTO(timestamp: $0.timestamp, modelID: $0.modelID, providerName: $0.providerName,
                       durationMs: $0.durationMs, totalTokens: $0.totalTokens, httpStatus: $0.httpStatus,
                       switched: $0.switched, ok: $0.ok, errorNote: $0.errorNote)
            },
            keysIncluded: includeKeys
        )
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        do {
            return try enc.encode(snapshot)
        } catch {
            throw BackupError.encodeFailed(error.localizedDescription)
        }
    }

    /// 加密：口令 → SHA256 密钥 → AES-GCM，输出 base64（带 FRB1 头）
    public func encrypt(_ data: Data, passphrase: String) throws -> Data {
        let key = SymmetricKey(data: SHA256.hash(data: Data(passphrase.utf8)))
        guard let sealed = try? AES.GCM.seal(data, using: key), let combined = sealed.combined else {
            throw BackupError.encodeFailed("AES-GCM 封装失败")
        }
        return Data("FRB1".utf8) + combined.base64EncodedData()
    }

    public func decrypt(_ data: Data, passphrase: String) throws -> Data {
        let head = Data("FRB1".utf8)
        guard data.count > head.count, data.prefix(head.count) == head else {
            throw BackupError.wrongFormat
        }
        let b64 = data.subdata(in: head.count..<data.count)
        guard let combined = Data(base64Encoded: b64) else { throw BackupError.decryptFailed }
        let key = SymmetricKey(data: SHA256.hash(data: Data(passphrase.utf8)))
        guard let box = try? AES.GCM.SealedBox(combined: combined) else { throw BackupError.decryptFailed }
        guard let plain = try? AES.GCM.open(box, using: key) else { throw BackupError.decryptFailed }
        return plain
    }

    public func isEncrypted(_ data: Data) -> Bool {
        data.prefix(4) == Data("FRB1".utf8)
    }

    /// 导入（写回数据库；Key 明文不会被覆盖，除非备份里包含）。
    /// ModelStore 是 @MainActor（SwiftData mainContext 如此），写库必须回主 actor；
    /// 调用点本来就在 SwiftUI 视图里，加标记即可，无需 await。
    @MainActor
    public func restore(_ data: Data, into app: AppState) throws -> ImportReport {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let snapshot: Snapshot
        do {
            snapshot = try dec.decode(Snapshot.self, from: data)
        } catch {
            throw BackupError.decodeFailed(error.localizedDescription)
        }
        guard snapshot.app == "FreeRoute AI" else { throw BackupError.wrongFormat }

        for p in snapshot.providers {
            try? app.store.saveProvider(p)
        }
        for p in snapshot.providers {
            try? app.store.upsertModels(snapshot.models.filter { $0.providerID == p.id }, for: p)
        }
        for l in snapshot.logs {
            try? app.store.appendLog(DBRequestLog(timestamp: l.timestamp, modelID: l.modelID,
                                                  providerName: l.providerName, durationMs: l.durationMs,
                                                  totalTokens: l.totalTokens, httpStatus: l.httpStatus,
                                                  switched: l.switched, ok: l.ok, errorNote: l.errorNote))
        }
        try? app.store.context.save()
        return ImportReport(providers: snapshot.providers.count, models: snapshot.models.count,
                            logs: snapshot.logs.count,
                            message: snapshot.keysIncluded ? "该备份包含密钥标记，请核对" : "已导入（密钥仍在钥匙串，未从备份覆盖）")
    }
}

extension BackupService.BackupError {
    fileprivate static func encryptFailureLocal() -> BackupService.BackupError { .encodeFailed("AES-GCM 封装失败") }
}

/// 导出文件类型
extension UTType {
    public static let freerouteBackup = UTType(exportedAs: "com.freeroute.ai.backup")
}
