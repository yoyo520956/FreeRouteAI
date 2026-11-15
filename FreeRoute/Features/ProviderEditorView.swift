import SwiftUI

/// 服务商新增 / 编辑（含密钥入钥匙串、连通测试）
struct ProviderEditorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    private let original: Provider?

    @State private var name: String
    @State private var kind: ProviderKind
    @State private var proto: ProviderProtocolType
    @State private var baseURL: String
    @State private var requestPath: String
    @State private var modelsPath: String
    @State private var embeddingsPath: String
    @State private var timeout: Double
    @State private var enabled: Bool
    @State private var notes: String
    @State private var headers: [HeaderRow]
    @State private var keyInput: String = ""
    @State private var showKey: Bool = false
    @State private var probeResult: ProbeResult?
    @State private var probing = false
    @State private var savedKeyMask: String
    @State private var alertText: String?
    @State private var showAlert = false

    private struct HeaderRow: Identifiable, Hashable {
        let id = UUID()
        var key: String
        var value: String
    }

    init(provider: Provider?) {
        original = provider
        let p = provider
        _name = State(initialValue: p?.name ?? "")
        _kind = State(initialValue: p?.kind ?? .custom)
        _proto = State(initialValue: p?.protocolType ?? .openaiCompatible)
        _baseURL = State(initialValue: p?.baseURL ?? "https://")
        _requestPath = State(initialValue: p?.requestPath ?? "")
        _modelsPath = State(initialValue: p?.modelsPath ?? "")
        _embeddingsPath = State(initialValue: p?.embeddingsPath ?? "")
        _timeout = State(initialValue: p?.timeout ?? 60)
        _enabled = State(initialValue: p?.enabled ?? true)
        _notes = State(initialValue: p?.notes ?? "")
        _headers = State(initialValue: (p?.customHeaders ?? [:]).sorted { $0.key < $1.key }
                            .map { HeaderRow(key: $0.key, value: $0.value) })
        _savedKeyMask = State(initialValue: {
            guard let p, let first = p.keys.first else { return "未设置" }
            return "已保存（\(first.label)，\(first.status.label)）"
        }())
    }

    private var baseURLValid: Bool {
        let trimmed = baseURL.trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return false }
        // 只有 scheme 不算合法：新建态默认就预填 "https://"，
        // 用 hasPrefix 判断会把它当成合法地址直接落库（真实缺陷）
        return !(url.host ?? "").isEmpty
    }
    private var nameValid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty }
    private var canSave: Bool { baseURLValid && nameValid }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("服务商名称", text: $name)
                        .accessibilityIdentifier("provider.name")
                    Picker("类型", selection: $kind) {
                        ForEach(ProviderKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Picker("协议", selection: $proto) {
                        ForEach(ProviderProtocolType.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    Toggle("启用", isOn: $enabled)
                }

                Section {
                    TextField("Base URL", text: $baseURL)
                        .accessibilityIdentifier("provider.baseURL")
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    if !baseURLValid {
                        Label("Base URL 需填完整地址（以 http:// 或 https:// 开头并含域名）", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11)).foregroundStyle(FRDesign.err)
                    }
                    TextField("请求路径（留空用协议默认）", text: $requestPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("模型列表路径（留空 = 不支持动态发现）", text: $modelsPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("向量路径（仅 OpenAI 兼容）", text: $embeddingsPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Stepper(value: $timeout, in: 5...300, step: 5) {
                        HStack {
                            Text("超时")
                            Spacer()
                            Text("\(Int(timeout)) 秒").foregroundStyle(.secondary)
                        }
                    }
                    Text("协议默认接口：\(proto.defaultModelsEndpoint)")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                } header: {
                    Text("接口地址")
                } footer: {
                    Text("把「模型列表路径」显式清空，表示这个服务商不提供模型目录接口，模型中心会如实显示「不支持动态发现」。")
                }

                Section("自定义 Headers") {
                    ForEach($headers) { $row in
                        HStack(spacing: 8) {
                            TextField("名称", text: $row.key)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            TextField("值", text: $row.value)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button {
                                headers.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(FRDesign.err)
                            }
                            .buttonStyle(.borderless)
                        }
                        .font(.system(size: 12))
                    }
                    Button {
                        headers.append(HeaderRow(key: "", value: ""))
                    } label: {
                        Label("添加 Header", systemImage: "plus.circle")
                    }
                }

                Section {
                    HStack {
                        Group {
                            if showKey {
                                TextField("API Key", text: $keyInput)
                            } else {
                                SecureField("API Key", text: $keyInput)
                            }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(.system(size: 12, design: .monospaced))
                        Button {
                            showKey.toggle()
                        } label: {
                            Image(systemName: showKey ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    HStack(spacing: 10) {
                        Button("保存到钥匙串") { saveKey() }
                            .disabled(keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                        Button("删除密钥", role: .destructive) { deleteKey() }
                            .disabled(savedKeyMask == "未设置")
                    }
                    .font(.system(size: 13))
                    HStack {
                        Text("当前：").foregroundStyle(.secondary)
                        Text(savedKeyMask).font(.system(size: 12, design: .monospaced))
                    }
                    Button {
                        runProbe()
                    } label: {
                        if probing {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("测试中…") }
                        } else {
                            Text("测试连接")
                        }
                    }
                    .disabled(original == nil || probing)
                    if let p = probeResult {
                        Label(p.message + (p.httpStatus.map { "（HTTP \($0)）" } ?? ""),
                              systemImage: p.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(p.ok ? FRDesign.ok : FRDesign.err)
                    }
                } header: {
                    Text("API Key")
                } footer: {
                    Text("密钥只写入 iPhone 钥匙串，数据库仅保存引用；导出备份默认不含明文密钥。")
                }

                Section("备注") {
                    TextField("免费额度、限流、地区限制等", text: $notes, axis: .vertical)
                        .lineLimit(2...5).font(.system(size: 12))
                }
            }
            .navigationTitle(original == nil ? "添加服务商" : "编辑服务商")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!canSave)
                }
            }
            .alert("提示", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertText ?? "")
            }
            .onDisappear { _ = app }
        }
    }

    // MARK: 动作

    private func buildProvider() -> Provider {
        var p = original ?? Provider(kind: kind, name: name.trimmingCharacters(in: .whitespaces),
                                    protocolType: proto, baseURL: baseURL.trimmingCharacters(in: .whitespaces))
        p.kind = kind
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.protocolType = proto
        p.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        p.requestPath = requestPath.isEmpty ? nil : requestPath
        // 显式输入空串表示"不支持动态发现"，保留 nil 则用协议默认
        p.modelsPath = modelsPath.isEmpty ? nil : modelsPath
        p.embeddingsPath = embeddingsPath.isEmpty ? nil : embeddingsPath
        p.timeout = timeout
        p.enabled = enabled
        p.notes = notes
        var dict: [String: String] = [:]
        for row in headers where !row.key.trimmingCharacters(in: .whitespaces).isEmpty {
            dict[row.key.trimmingCharacters(in: .whitespaces)] = row.value
        }
        p.customHeaders = dict
        return p
    }

    /// 校验必须落在动作里，不能只挂在按钮的 `.disabled()` 上。
    /// 修饰符一旦因任何原因失效（状态没刷新、自动化点击、以后换成别的控件），
    /// 非法配置就直接落库 —— UI 测试真的把 "not-a-url" 存进去过。
    private var blockingMessage: String? {
        if !nameValid { return "请填写服务商名称" }
        if !baseURLValid { return "Base URL 需填完整地址（以 http:// 或 https:// 开头并含域名）" }
        return nil
    }

    /// 返回 false 表示被校验拦住，调用方必须中止
    private func refuseInvalidInput() -> Bool {
        guard let msg = blockingMessage else { return false }
        alertText = msg
        showAlert = true
        return true
    }

    private func save() {
        if refuseInvalidInput() { return }
        let p = buildProvider()
        if original == nil {
            app.addProvider(p)
        } else {
            app.updateProvider(p)
        }
        dismiss()
    }

    private func saveKey() {
        if refuseInvalidInput() { return }
        let p = buildProvider()
        // 新服务商要先落库，才有 id 可以生成钥匙串引用
        if original == nil { app.addProvider(p) }
        let target = app.providers.first(where: { $0.id == p.id }) ?? p
        let trimmed = keyInput.trimmingCharacters(in: .whitespaces)
        let ok = app.setKey(trimmed, provider: target)
        savedKeyMask = ok ? KeychainStore.mask(trimmed) : "未设置"
        if !ok {
            alertText = "钥匙串写入失败，请确认设备已设置锁屏密码"
            showAlert = true
        } else {
            keyInput = ""
        }
    }

    private func deleteKey() {
        let p = buildProvider()
        guard let target = app.providers.first(where: { $0.id == p.id }) else { return }
        app.deleteKey(provider: target)
        savedKeyMask = "未设置"
    }

    private func runProbe() {
        let p = buildProvider()
        guard let target = app.providers.first(where: { $0.id == p.id }) else {
            alertText = "请先保存服务商再测试"
            showAlert = true
            return
        }
        probing = true
        Task {
            let r = await app.probe(provider: target)
            probeResult = r
            probing = false
        }
    }
}
