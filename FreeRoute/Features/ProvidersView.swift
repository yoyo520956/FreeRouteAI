import SwiftUI

/// 服务商管理：列表 + 启用开关 + 密钥状态 + 测试/刷新/编辑/删除
/// 既可作为 sheet 呈现（自动出现「完成」按钮），也可嵌入其它导航栈作为子页。
struct ProvidersView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented

    @State private var editingProvider: Provider?
    @State private var showEditor: Bool = false
    @State private var deleteTarget: Provider?
    @State private var showDeleteDialog: Bool = false
    @State private var busyProviderID: UUID?
    @State private var resultTitle: String = ""
    @State private var resultText: String = ""
    @State private var showResult: Bool = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 9) {
                header
                keychainHint
                if app.providers.isEmpty {
                    FREmptyState(icon: "server.rack",
                                 title: "还没有服务商",
                                 detail: "添加一个 OpenAI 兼容端点，或从内置模板开始。\nAPI Key 只会保存在 iPhone 钥匙串里。",
                                 actionTitle: "添加自定义服务商") {
                        editingProvider = nil
                        showEditor = true
                    }
                } else {
                    ForEach(app.providers) { p in
                        PVRow(provider: p,
                              modelCount: app.models(of: p).count,
                              maskedKey: app.maskedKey(for: p),
                              busy: busyProviderID == p.id,
                              onToggle: { on in app.setEnabled(on, provider: p) },
                              onProbe: { runProbe(p) },
                              onRefresh: { runRefresh(p) },
                              onEdit: { editingProvider = p; showEditor = true },
                              onDelete: { deleteTarget = p; showDeleteDialog = true })
                    }
                }
                addButtons
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 26)
        }
        .background(FRBackground())
        .sheet(isPresented: $showEditor) {
            ProviderEditorView(provider: editingProvider)
        }
        .confirmationDialog(deleteTitle, isPresented: $showDeleteDialog, presenting: deleteTarget) { p in
            Button("删除 \(p.name)", role: .destructive) {
                app.deleteProvider(p)
                deleteTarget = nil
            }
            Button("取消", role: .cancel) { deleteTarget = nil }
        } message: { p in
            Text("将同时删除钥匙串中的 \(p.keys.count) 条密钥与本地已发现的 \(app.models(of: p).count) 个模型记录。此操作不可撤销。")
        }
        .alert(resultTitle, isPresented: $showResult) {
            Button("好", role: .cancel) {}
        } message: {
            Text(resultText)
        }
    }

    private var deleteTitle: String {
        "删除服务商？"
    }

    // MARK: 头部

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("服务商管理").font(.system(size: 17, weight: .bold))
                Text("\(app.providers.count) 个服务商 · \(app.providers.filter { $0.enabled }.count) 个已启用 · \(app.models.count) 个模型")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isPresented {
                Button {
                    dismiss()
                } label: {
                    Text("完成")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 13).padding(.vertical, 6)
                        .background(Capsule().fill(FRDesign.accent.opacity(0.16)))
                        .foregroundStyle(FRDesign.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("完成")
            }
        }
        .padding(.top, 4)
    }

    private var keychainHint: some View {
        FRCard(padding: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(FRDesign.ok)
                Text("API Key 只存 iPhone 钥匙串（Keychain），数据库里只保存引用与掩码；备份导出也不含明文密钥。删除服务商会一并清除对应密钥。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var addButtons: some View {
        VStack(spacing: 8) {
            Button {
                editingProvider = nil
                showEditor = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                    Text("添加自定义服务商").font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Capsule().fill(FRDesign.accent.opacity(0.18)))
                .foregroundStyle(FRDesign.accent)
            }
            .buttonStyle(.plain)

            NavigationLink {
                FreeCatalogView()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe")
                    Text("从全球免费服务商目录添加").font(.system(size: 12.5))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color(.secondarySystemGroupedBackground)))
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 4)
    }

    // MARK: 动作

    private func runProbe(_ p: Provider) {
        guard busyProviderID == nil else { return }
        busyProviderID = p.id
        Task { @MainActor in
            let r = await app.probe(provider: p)
            busyProviderID = nil
            resultTitle = r.ok ? "\(p.name)：连接正常" : "\(p.name)：连接失败"
            var lines = [r.message]
            lines.append("耗时 " + FRFormat.ms(r.latencyMs))
            if let s = r.httpStatus { lines.append("HTTP \(s)") }
            resultText = lines.joined(separator: "\n")
            showResult = true
        }
    }

    private func runRefresh(_ p: Provider) {
        guard busyProviderID == nil else { return }
        busyProviderID = p.id
        Task { @MainActor in
            let r = await app.refreshModels(provider: p)
            busyProviderID = nil
            resultTitle = p.name
            if let e = r.error {
                resultText = e
            } else {
                resultText = "新增 \(r.added) 个模型，当前共 \(r.total) 个"
            }
            showResult = true
        }
    }
}

// MARK: - 服务商行

private struct PVRow: View {
    let provider: Provider
    let modelCount: Int
    let maskedKey: String
    let busy: Bool
    let onToggle: (Bool) -> Void
    let onProbe: () -> Void
    let onRefresh: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    private var keyStatus: String { provider.keys.first?.status.label ?? "未设置密钥" }

    var body: some View {
        FRCard(padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Toggle(isOn: Binding(get: { provider.enabled }, set: { onToggle($0) })) {
                        Text(provider.name)
                            .font(.system(size: 13.5, weight: .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .toggleStyle(.switch)
                    .tint(FRDesign.accent)
                    Spacer(minLength: 4)
                    Menu {
                        Button { onProbe() } label: { Label("测试连接", systemImage: "bolt") }
                        Button { onRefresh() } label: { Label("刷新模型", systemImage: "arrow.clockwise") }
                        Button { onEdit() } label: { Label("编辑", systemImage: "pencil") }
                        Divider()
                        Button(role: .destructive) { onDelete() } label: { Label("删除服务商", systemImage: "trash") }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 16))
                            .foregroundStyle(FRDesign.accent)
                    }
                }

                HStack(spacing: 5) {
                    FRBadge(provider.kind.displayName, color: FRDesign.accentCyan)
                    FRBadge(provider.protocolType.displayName, color: .secondary)
                    if provider.freeQuota?.hasFreeTier == true {
                        FRBadge("有免费层", color: FRDesign.ok, icon: "zap")
                    }
                    Spacer(minLength: 0)
                    if busy { ProgressView().controlSize(.small) }
                }

                HStack(spacing: 5) {
                    FRStatusDot(color: pvKeyColor(provider.keys.first?.status ?? .unknown))
                    Text(maskedKey)
                        .font(.system(size: 10.5, design: .monospaced))
                        .lineLimit(1)
                    Text(keyStatus)
                        .font(.system(size: 10))
                        .foregroundStyle(pvKeyColor(provider.keys.first?.status ?? .unknown))
                    Spacer(minLength: 3)
                    Text("\(modelCount) 模型")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Text(baseURLLine)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if !provider.notes.isEmpty {
                    let note = provider.notes
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .opacity(provider.enabled ? 1 : 0.55)
    }

    private var baseURLLine: String {
        var s = provider.baseURL
        if let rp = provider.requestPath { s += "  →  " + rp }
        return s
    }
}

private func pvKeyColor(_ s: KeyStatus) -> Color {
    switch s {
    case .healthy: return FRDesign.ok
    case .unauthorized, .forbidden: return FRDesign.err
    case .rateLimited: return FRDesign.warn
    case .disabled: return .secondary
    case .unknown: return FRDesign.accentCyan
    }
}
