import SwiftUI

/// Prompt 管理：新增 / 编辑 / 删除本机保存的 prompt 模板。
/// 与网关 /v1/prompts 读写同一份 PromptStore（无影子副本）。
struct PromptManagerView: View {
    @State private var prompts: [StoredPrompt] = []
    @State private var editing: StoredPrompt?
    @State private var showEditor = false
    @State private var deleting: StoredPrompt?

    private let store = PromptStore()

    var body: some View {
        Form {
            Section {
                if prompts.isEmpty {
                    Text("还没有保存任何 prompt。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(prompts) { p in
                        Button {
                            editing = p
                            showEditor = true
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.primary)
                                Text(p.content)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                HStack(spacing: 6) {
                                    Text(AgentTime.iso(p.updatedAt))
                                    if !p.tags.isEmpty {
                                        Text(p.tags.joined(separator: " · "))
                                    }
                                }
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete { offsets in
                        for idx in offsets {
                            _ = store.delete(id: prompts[idx].id)
                        }
                        reload()
                    }
                }
            } header: {
                Text("已保存 (\(prompts.count))")
            } footer: {
                Text("Prompt 仅存本机。Agent 请求里传 prompt=名称 即可自动注入该内容为 system 提示。")
            }
        }
        .navigationTitle("Prompt 模板")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    editing = nil
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("新建 prompt")
            }
        }
        .sheet(isPresented: $showEditor) {
            PromptEditorView(existing: editing) { name, content, tags in
                _ = store.upsert(name: name, content: content, tags: tags)
                reload()
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        prompts = store.all()
    }
}

/// 新建 / 编辑单个 prompt
private struct PromptEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existing: StoredPrompt?
    let onSave: (String, String, [String]) -> Void

    @State private var name: String = ""
    @State private var content: String = ""
    @State private var tags: String = ""
    @State private var showError = false

    var body: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如：代码审查", text: $name)
                        .textInputAutocapitalization(.never)
                }
                Section {
                    TextEditor(text: $content)
                        .frame(minHeight: 180)
                } header: {
                    Text("内容")
                } footer: {
                    Text("将作为 system 提示注入 Agent 会话。")
                }
                Section("标签") {
                    TextField("逗号分隔，例如：开发,审查", text: $tags)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(existing == nil ? "新建 Prompt" : "编辑 Prompt")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || content.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .alert("内容不完整", isPresented: $showError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("名称与内容都不能为空。")
            }
        }
        .onAppear {
            if let e = existing {
                name = e.name; content = e.content; tags = e.tags.joined(separator: ",")
            }
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !c.isEmpty else {
            showError = true
            return
        }
        let tagList = tags.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        onSave(n, c, tagList)
        dismiss()
    }
}
