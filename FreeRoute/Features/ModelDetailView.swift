import SwiftUI

/// 模型详情：全部字段 + 真实测试 + 在路由中的六维评分
struct ModelDetailView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss

    let model: ModelInfo
    @State private var testing = false
    @State private var testResult: ProbeResult?
    @State private var showScores = false

    private var provider: Provider? {
        app.providers.first { $0.id == model.providerID }
    }

    var body: some View {
            ZStack {
                FRBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        headerCard
                        actionCard
                        specCard
                        capabilityCard
                        if let p = provider { ownerCard(p) }
                        if let quota = provider?.freeQuota { quotaCard(quota) }
                        scoreCard
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
            }
            .navigationTitle("模型详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
    }

    // MARK: 头部

    private var headerCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.displayName).font(.system(size: 18, weight: .bold))
                Text(model.modelID)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    FRStatusDot(color: healthColor(model.health), pulse: model.health == .healthy)
                    Text(model.health.label).font(.system(size: 11)).foregroundStyle(healthColor(model.health))
                    if model.isFreeTier { FRBadge("免费", color: FRDesign.ok, icon: "gift") }
                    else { FRBadge("付费", color: FRDesign.warn, icon: "creditcard") }
                    if model.successRate > 0 {
                        FRBadge("成功率 " + FRFormat.percent(model.successRate), color: FRDesign.accentCyan)
                    }
                }
            }
        }
    }

    // MARK: 操作

    private var actionCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        runTest()
                    } label: {
                        if testing {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("测试中…")
                            }
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(FRDesign.accent.opacity(0.15)))
                        } else {
                            Text("测试此模型")
                                .font(.system(size: 13, weight: .medium))
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(FRDesign.accent))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(testing)

                    Button {
                        showScores.toggle()
                    } label: {
                        Text("查看路由评分")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(Capsule().fill(FRDesign.accentCyan.opacity(0.16)))
                            .foregroundStyle(FRDesign.accentCyan)
                    }
                    .buttonStyle(.plain)
                }
                if let r = testResult {
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: r.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(r.ok ? FRDesign.ok : FRDesign.err)
                            .font(.system(size: 12))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.ok ? "测试通过（\(FRFormat.ms(r.latencyMs))）" : "测试失败（\(FRFormat.ms(r.latencyMs))）")
                                .font(.system(size: 12, weight: .medium))
                            Text(r.message).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: 规格

    private var specCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 7) {
                Text("规格").font(.system(size: 13, weight: .semibold))
                row("上下文", FRFormat.context(model.contextLength))
                row("最大输出", FRFormat.context(model.maxOutputTokens))
                row("输入价格", model.inputPricePer1K.map { String(format: "$%.5f / 1K", $0) } ?? "未提供")
                row("输出价格", model.outputPricePer1K.map { String(format: "$%.5f / 1K", $0) } ?? "未提供")
                row("历史延迟", model.avgLatencyMs.map { FRFormat.ms($0) } ?? "无数据")
                row("最后刷新", model.lastRefreshed == .distantPast ? "从未" : FRFormat.dateTime(model.lastRefreshed))
                row("最后测试", model.lastTested.map { FRFormat.dateTime($0) } ?? "从未")
                if !model.note.isEmpty {
                    Divider().opacity(0.4)
                    Text(model.note).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var capabilityCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("能力").font(.system(size: 13, weight: .semibold))
                FlowingBadges(items: model.capabilities.map { $0.label })
            }
        }
    }

    private func ownerCard(_ p: Provider) -> some View {
        FRCard {
            VStack(alignment: .leading, spacing: 7) {
                Text("所属服务商").font(.system(size: 13, weight: .semibold))
                row("名称", p.name)
                row("类型", p.kind.displayName)
                row("协议", p.protocolType.displayName)
                row("Base URL", p.baseURL)
                row("密钥", app.maskedKey(for: p))
                row("状态", p.keys.first?.status.label ?? "未配置")
            }
        }
    }

    private func quotaCard(_ q: FreeQuotaInfo) -> some View {
        FRCard {
            VStack(alignment: .leading, spacing: 7) {
                Text("免费额度说明").font(.system(size: 13, weight: .semibold))
                row("额度", q.quotaNote)
                row("限流", q.rateLimitNote)
                row("地区", q.regionNote)
                row("注册", q.registrationNote)
                row("账户", q.accountNote)
                row("免费模型", q.freeModelsNote)
                Text("最后验证：\(q.lastVerifiedISO)，以官网为准")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 路由评分（真实调用路由器）

    private var scoreCard: some View {
        Group {
            if showScores {
                FRCard {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text("在 \(app.router.mode.rawValue) 下的评分").font(.system(size: 13, weight: .semibold))
                            Spacer()
                        }
                        if let score = routeScore {
                            HStack {
                                Text(String(format: "总分 %.3f", max(0, score.score)))
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(FRDesign.accent)
                                Spacer()
                                if score.blocked, let reason = score.blockReason {
                                    FRBadge(reason, color: FRDesign.err)
                                }
                            }
                            // 六维评分表：用 Grid 让「标签列/数值列」按内容自动对齐，
                            // 取代原先 68pt / 38pt 两个魔数（大字号下必溢出）
                            Grid(alignment: .center, horizontalSpacing: 8, verticalSpacing: 5) {
                                ForEach(Array(score.parts.enumerated()), id: \.offset) { _, part in
                                    GridRow(alignment: .center) {
                                        Text(part.name).font(.system(size: 11))
                                            .fixedSize()
                                            .gridColumnAlignment(.leading)
                                        GeometryReader { geo in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Color(.tertiarySystemFill)).frame(height: 5)
                                                Capsule().fill(FRDesign.accent)
                                                    .frame(width: max(2, geo.size.width * CGFloat(part.raw)), height: 5)
                                            }
                                        }
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 5)
                                        Text(String(format: "%.2f", part.weighted))
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .fixedSize()
                                            .gridColumnAlignment(.trailing)
                                    }
                                }
                            }
                            Text(score.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("该模型未进入候选池（服务商可能已停用或缺少密钥）")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var routeScore: RouteScore? {
        let ranked = app.router.preview(candidates: app.candidates())
        return ranked.first { $0.candidate.model.id == model.id }
    }

    // MARK: 工具

    private func row(_ k: String, _ v: String) -> some View {
        // 原来固定 64pt 标签列在超大字号/窄屏下会把值挤裁，改用两态自适应行
        FRKeyValueRow(k, v)
    }

    private func healthColor(_ h: ModelHealth) -> Color {
        switch h {
        case .healthy: return FRDesign.ok
        case .degraded: return FRDesign.warn
        case .failing: return FRDesign.err
        case .cooldown: return FRDesign.warn
        case .unknown: return Color(.systemGray)
        }
    }

    private func runTest() {
        testing = true
        Task {
            let r = await app.test(model: model)
            testResult = r
            testing = false
        }
    }
}

/// 自动换行的徽标行（小屏友好）
struct FlowingBadges: View {
    let items: [String]
    private let columns = [GridItem(.adaptive(minimum: 74), spacing: 6)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                FRBadge(item, color: FRDesign.accentCyan)
            }
        }
    }
}
