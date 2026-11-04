import Foundation
import Security

/// 字符串 Keychain 存储（API Key、网关 Token 全部只存这里，数据库不存明文）
public final class KeychainStore: Sendable {
    private let service: String
    private let accessGroup: String?

    public init(service: String = "com.freeroute.ai", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func baseQuery() -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if let accessGroup {
            q[kSecAttrAccessGroup as String] = accessGroup
        }
        return q
    }

    @discardableResult
    public func set(_ value: String, for key: String) -> Bool {
        var query = baseQuery()
        query[kSecAttrAccount as String] = key
        let data = value.data(using: .utf8)!
        var status = SecItemDelete(query as CFDictionary)
        if status == errSecItemNotFound { status = noErr }
        query[kSecValueData as String] = data
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public func get(_ key: String) -> String? {
        var query = baseQuery()
        query[kSecAttrAccount as String] = key
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitFirst
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func delete(_ key: String) -> Bool {
        var query = baseQuery()
        query[kSecAttrAccount as String] = key
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    public func deleteAll() {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        SecItemDelete(query as CFDictionary)
    }

    /// 展示用掩码：前 4 + … + 后 4（短于 10 位显示长度）
    public static func mask(_ key: String) -> String {
        guard key.count > 10 else { return String(repeating: "•", count: key.count) }
        return String(key.prefix(4)) + "…" + String(key.suffix(4))
    }
}
