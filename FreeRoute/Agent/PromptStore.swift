import Foundation

// MARK: - Prompt 存储
// 用户自定义 prompt（任务模板、角色设定、常用指令），持久化到 UserDefaults
// （无敏感信息；密钥类永远不进 UserDefaults，见 ToolPermissionStore 约定）。
// /v1/prompts 端点与 Agent 模式 `prompt` 字段都读写这一份数据，无影子副本。

public struct StoredPrompt: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var content: String
    public var tags: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = "prompt_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased(),
                name: String, content: String, tags: [String] = []) {
        self.id = id; self.name = name; self.content = content; self.tags = tags
        self.createdAt = Date(); self.updatedAt = Date()
    }

    public var asJSONObject: [String: Any] {
        [
            "id": id, "name": name, "content": content, "tags": tags,
            "created_at": AgentTime.iso(createdAt), "updated_at": AgentTime.iso(updatedAt)
        ]
    }
}

public final class PromptStore: @unchecked Sendable {
    private let defaults = UserDefaults.standard
    private let key = "freeroute.prompts.v1"
    private let lock = NSLock()

    public init() {}

    public func all() -> [StoredPrompt] {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              let list = try? JSONDecoder().decode([StoredPrompt].self, from: data) else { return [] }
        return list.sorted { $0.updatedAt > $1.updatedAt }
    }

    public func find(name: String) -> StoredPrompt? {
        all().first { $0.name.lowercased() == name.lowercased() }
    }

    @discardableResult
    public func upsert(name: String, content: String, tags: [String] = []) -> StoredPrompt {
        lock.lock(); defer { lock.unlock() }
        var list: [StoredPrompt] = []
        if let data = defaults.data(forKey: key) {
            list = (try? JSONDecoder().decode([StoredPrompt].self, from: data)) ?? []
        }
        if let idx = list.firstIndex(where: { $0.name == name }) {
            list[idx].content = content
            list[idx].tags = tags.isEmpty ? list[idx].tags : tags
            list[idx].updatedAt = Date()
            defaults.set(try? JSONEncoder().encode(list), forKey: key)
            return list[idx]
        }
        let p = StoredPrompt(name: name, content: content, tags: tags)
        list.append(p)
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
        return p
    }

    public func delete(id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let data = defaults.data(forKey: key),
              var list = try? JSONDecoder().decode([StoredPrompt].self, from: data) else { return false }
        guard let idx = list.firstIndex(where: { $0.id == id }) else { return false }
        _ = list.remove(at: idx)
        defaults.set(try? JSONEncoder().encode(list), forKey: key)
        return true
    }
}