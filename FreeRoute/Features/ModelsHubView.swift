import SwiftUI

/// 模型中心：搜索 + 能力筛选 + 健康/延迟总览
/// 首页级页面，内部自带 NavigationStack。
struct ModelsHubView: View {
    @Environment(AppState.self) private var app

    @State private var query: String = ""
    @State private var filter: MHFilter = .all
    @State private var refreshing: Bool = false
    @State private var alertText: String = ""
    @State private var showAlert: Bool = false
    @State private var showProviders: Bool = false
    @State private var showCatalog: Bool = false

    // MARK: 数据

    private var visible: [ModelInfo] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return app.models
            .filter { mhMatches($0, query: q) }
            .sorted {
                if $0.providerName != $1.providerName { return $0.providerName < $1.providerName }
                return $0.displayName < $1.displayName
            }
    }

    private func mhMatches(_ m: ModelInfo, query q: String) -> Bool {
        guard filter.matches(m) else { return false }
        if q.isEmpty { return true }
        return m.displayName.localizedCaseInsensitiveContains(q)
            || m.modelID.localizedCaseInsensitiveContains(q)
            || m.providerName.localizedCaseInsensitiveContains(q)
    }

    private var freeCount: Int { app.models.filter { $0.isFreeTier }.count }
    private var enabledProviderCount: Int { app.providers.filter { $0.enabled }.count }
    private var usableProviderCount: Int { app.providers.filter { $0.enabled && $0.hasUsableKey }.count }

    // MARK: 界面

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 9) {
                    summaryCard
                    MHFilterBar(filter: $filter, models: app.models)
                    contentList
                }
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 26)
            }
            .background(FRBackground())
            .navigationTitle("模型中心")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索模型 / 服务商")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        runRefreshAll()
                    } label: {
                        Image(systemName: refreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .disabled(refreshing || app.providers.isEmpty)
                    .accessibilityLabel("刷新全部")

                    Menu {
                        Button {
                            showProviders = true
                        } label: {
                            Label("添加服务商", systemImage: "plus.circle")
                        }
                        .accessibilityIdentifier("addProvider")
                        Button {
                            showCatalog = true
                        } label: {
                            Label("免费目录", systemImage: "globe")
                        }
                        Button {
                            runRefreshAll()
                        } label: {
                            Label("刷新全部", systemImage: "arrow.clockwise")
                        }
                        .accessibilityIdentifier("refreshAll")
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    // UI 测试定位点：SF Symbol 按钮的默认可访问性标签不稳定，
                    // 用显式 identifier（同时给读屏用户一个真实名称）
                    .accessibilityIdentifier("moreActions")
                    .accessibilityLabel("更多操作")
                    .disabled(refreshing)
                }
            }
            .navigationDestination(for: ModelInfo.self) { m in
                ModelDetailView(model: m)
            }
            .sheet(isPresented: $showProviders) {
                ProvidersView()
            }
            .sheet(isPresented: $showCatalog) {
                FreeCatalogView()
            }
            .alert("刷新结果", isPresented: $showAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(alertText)
            }
            .overlay {
                if refreshing {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在向各服务商拉取模型列表…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.regularMaterial))
                }
            }
        }
    }

    // MARK: 顶部概览

    private var summaryCard: some View {
        FRCard(padding: 11) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    mhStat(title: "模型", value: FRFormat.compact(app.models.count), icon: "cube.box")
                    mhStat(title: "免费", value: FRFormat.compact(freeCount), icon: "zap",
                           tint: FRDesign.ok)
                    mhStat(title: "服务商", value: "\(enabledProviderCount)/\(app.providers.count)",
                           icon: "server.rack", tint: FRDesign.accentCyan)
                    mhStat(title: "有密钥", value: "\(usableProviderCount)", icon: "key",
                           tint: usableProviderCount > 0 ? FRDesign.ok : FRDesign.warn)
                }
                Text("筛选出 \(visible.count) 个模型 · 点击任意行查看健康、价格与路由评分")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func mhStat(title: String, value: String, icon: String, tint: Color = FRDesign.accent) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                Text(title).font(.system(size: 9.5)).foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.6).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: 列表 / 空态

    @ViewBuilder private var contentList: some View {
        if app.isBootstrapping {
            FRCard {
                HStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text("正在读取本地模型数据库…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        } else if app.models.isEmpty {
            VStack(spacing: 8) {
                FREmptyState(icon: "cube.box",
                             title: "还没有任何模型",
                             detail: "模型来自各服务商的模型目录接口。\n添加服务商并填入 API Key 后，点右上角「刷新全部」即可拉取真实模型列表。",
                             actionTitle: "添加服务商") {
                    showProviders = true
                }
                Button {
                    showCatalog = true
                } label: {
                    Text("浏览全球免费服务商目录")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(FRDesign.accentCyan)
                }
                .buttonStyle(.plain)
            }
        } else if visible.isEmpty {
            FREmptyState(icon: "magnifyingglass",
                         title: "没有匹配的模型",
                         detail: "当前关键词与筛选条件下没有结果。换个关键词，或把筛选切回「全部」。",
                         actionTitle: "清除筛选") {
                query = ""
                filter = .all
            }
        } else {
            ForEach(visible) { m in
                NavigationLink(value: m) {
                    ModelCardRow(model: m)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 动作

    @MainActor
    private func runRefreshAll() {
        guard !refreshing else { return }
        refreshing = true
        Task { @MainActor in
            let reports = await app.refreshAllEnabled()
            refreshing = false
            alertText = mhReportText(reports)
            showAlert = true
        }
    }
}

// MARK: - 筛选维度

private enum MHFilter: Int, CaseIterable, Identifiable {
    case all, free, text, image, audio, embeddings, rerank

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .free: return "免费"
        case .text: return "文本"
        case .image: return "图像"
        case .audio: return "语音"
        case .embeddings: return "向量"
        case .rerank: return "重排"
        }
    }

    func matches(_ m: ModelInfo) -> Bool {
        switch self {
        case .all: return true
        case .free: return m.isFreeTier
        case .text: return m.capabilities.contains(.text)
        case .image: return m.capabilities.contains(.image)
        case .audio: return m.capabilities.contains(.audio) || m.capabilities.contains(.audioOutput)
        case .embeddings: return m.capabilities.contains(.embeddings)
        case .rerank: return m.capabilities.contains(.rerank)
        }
    }

    func count(in models: [ModelInfo]) -> Int { models.filter { matches($0) }.count }
}

/// 小屏友好的横向筛选 chip 条
private struct MHFilterBar: View {
    @Binding var filter: MHFilter
    let models: [ModelInfo]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MHFilter.allCases) { f in
                    Button {
                        filter = f
                    } label: {
                        HStack(spacing: 3) {
                            Text(f.title).font(.system(size: 12, weight: .medium))
                            Text("\(f.count(in: models))")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(filter == f ? FRDesign.accent.opacity(0.18)
                                                                : Color(.secondarySystemGroupedBackground)))
                        .overlay(Capsule().strokeBorder(filter == f ? FRDesign.accent.opacity(0.5)
                                                                    : Color.clear, lineWidth: 1))
                        .foregroundStyle(filter == f ? FRDesign.accent : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(f.title) \(f.count(in: models)) 个")
                }
            }
            .padding(.vertical, 2)
        }
    }
}

// MARK: - 单行模型卡片

private struct ModelCardRow: View {
    let model: ModelInfo

    private var caps: [ModelCapability] { Array(model.capabilities.prefix(3)) }
    private var extraCapCount: Int { max(0, model.capabilities.count - caps.count) }

    var body: some View {
        FRCard(padding: 11) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    if model.isFreeTier {
                        FRBadge("免费", color: FRDesign.ok, icon: "zap")
                    }
                    Spacer(minLength: 3)
                    HStack(spacing: 4) {
                        FRStatusDot(color: mhHealthColor(model.health),
                                    pulse: model.health == .healthy)
                        Text(model.health.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                HStack(spacing: 5) {
                    Text(model.providerName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(FRDesign.accentCyan)
                        .lineLimit(1)
                    Text("上下文 \(FRFormat.context(model.contextLength))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 3)
                    Text(mhLatencyText)
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 5) {
                    ForEach(caps, id: \.self) { c in
                        FRBadge(c.label, color: FRDesign.accent)
                    }
                    if extraCapCount > 0 {
                        FRBadge("+\(extraCapCount)", color: .secondary)
                    }
                    if let out = model.maxOutputTokens {
                        FRBadge("输出 " + FRFormat.compact(out), color: .secondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Text("成功率 \(FRFormat.percent(model.successRate))")
                    Text("刷新 \(FRFormat.dateTime(model.lastRefreshed))")
                    Spacer()
                }
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var mhLatencyText: String {
        guard let ms = model.avgLatencyMs else { return "延迟 未测" }
        return "延迟 " + FRFormat.ms(ms)
    }
}

private func mhHealthColor(_ h: ModelHealth) -> Color {
    switch h {
    case .healthy: return FRDesign.ok
    case .degraded: return FRDesign.warn
    case .failing: return FRDesign.err
    case .cooldown: return FRDesign.accentCyan
    case .unknown: return Color.secondary
    }
}

private func mhReportText(_ reports: [AppState.RefreshReport]) -> String {
    if reports.isEmpty {
        return "没有已启用的服务商。请先添加服务商并打开它的开关。"
    }
    var lines: [String] = []
    for r in reports.prefix(8) {
        if let e = r.error {
            lines.append("\(r.providerName)：\(e)")
        } else {
            lines.append("\(r.providerName)：新增 \(r.added) 个模型，当前共 \(r.total) 个")
        }
    }
    if reports.count > 8 { lines.append("其余 \(reports.count - 8) 个服务商的结果已省略") }
    return lines.joined(separator: "\n")
}
