import SwiftUI

/// Smart 路由：模式选择、六维权重调校、候选排名、决策说明
struct SmartRouterView: View {
    @Environment(AppState.self) private var app
    @Environment(AppCoordinator.self) private var coordinator
    /// 布局只认 size class，不认机型：宽屏（iPad/横屏/Mac 宽窗）多列，窄屏两列
    @Environment(\.horizontalSizeClass) private var hSize

    // 排名缓存（避免在 body 里做有副作用调用）
    @State private var ranked: [RouteScore] = []
    @State private var showAll = false
    @State private var evaluating = false

    // 权重草稿：0...0.6，步长 0.01
    @State private var wHealth = 0.25
    @State private var wFree = 0.20
    @State private var wSuccess = 0.20
    @State private var wLatency = 0.15
    @State private var wLoad = 0.10
    @State private var wCap = 0.10

    var body: some View {
        NavigationStack {
            ZStack {
                FRBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        modeSection
                        weightSection
                        rankingSection
                        decisionSection
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .refreshable { reevaluate() }
            }
            .navigationTitle("Smart 路由")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reevaluate()
                    } label: {
                        if evaluating {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(evaluating)
                    .accessibilityLabel("重新评估")
                }
            }
            .task {
                syncDraft()
                reevaluate()
            }
            .onChange(of: app.router.mode) { _, _ in
                syncDraft()
                reevaluate()
            }
        }
    }

    // MARK: 模式

    private var modeSection: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("路由模式").font(.system(size: 13, weight: .semibold))
                LazyVGrid(columns: FRLayout.grid(hSize, compact: 2, regular: 4), spacing: 8) {
                    ForEach(RouterMode.allCases) { m in
                        modeCard(m)
                    }
                }
            }
        }
    }

    private func modeCard(_ m: RouterMode) -> some View {
        let selected = app.router.mode == m
        return Button {
            app.router.mode = m
            app.settings.defaultRouterMode = m
            app.saveSettings()
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(m.rawValue)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(selected ? FRDesign.accent : Color.secondary)
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13))
                        .foregroundStyle(selected ? FRDesign.accent : Color.secondary.opacity(0.4))
                }
                Text(m.label).font(.system(size: 13, weight: .semibold))
                Text(m.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? FRDesign.accent.opacity(0.12) : Color(.secondarySystemGroupedBackground).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? FRDesign.accent.opacity(0.6) : Color.black.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(m.label)，\(selected ? "已选中" : "未选中")")
    }

    // MARK: 权重

    private var weightSection: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("权重").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if app.router.weightsOverride != nil {
                        FRBadge("自定义", color: FRDesign.warn, icon: "slider.horizontal.3")
                    } else {
                        FRBadge("跟随模式默认", color: FRDesign.accentCyan, icon: "arrow.triangle.branch")
                    }
                }
                ForEach(weightItems) { item in
                    weightRow(key: item.key, title: item.title, color: item.color, binding: item.binding)
                }
                Button {
                    app.router.weightsOverride = nil
                    syncDraft()
                    reevaluate()
                } label: {
                    Label("恢复模式默认权重", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(FRDesign.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FRDesign.accent.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(app.router.weightsOverride == nil)
                .opacity(app.router.weightsOverride == nil ? 0.4 : 1)
            }
        }
    }

    private var weightItems: [WeightItem] {
        [
            WeightItem(key: "健康状态", title: "健康", color: FRDesign.ok, binding: healthBinding),
            WeightItem(key: "免费额度", title: "免费", color: FRDesign.warn, binding: freeBinding),
            WeightItem(key: "历史成功率", title: "成功率", color: FRDesign.accentCyan, binding: successBinding),
            WeightItem(key: "响应延迟", title: "延迟", color: FRDesign.accent, binding: latencyBinding),
            WeightItem(key: "当前负载", title: "负载", color: Color.purple, binding: loadBinding),
            WeightItem(key: "能力匹配", title: "能力", color: Color.pink, binding: capBinding)
        ]
    }

    private func weightRow(key: String, title: String, color: Color, binding: Binding<Double>) -> some View {
        let frac = app.router.activeWeights[key]
        return VStack(spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(FRFormat.percent(frac))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
            }
            Slider(value: binding, in: 0...0.6, step: 0.01) { editing in
                if !editing { reevaluate() }
            } label: {
                EmptyView()
            }
            .tint(color)
        }
        .padding(.vertical, 2)
    }

    // MARK: 排名

    private var rankingSection: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                // 窄屏/大字号放不下时整体退成上下排（原先写死 150pt 会截断）
                FRAdaptiveHeader(controlWidth: 150) {
                    Text("候选排名").font(.system(size: 13, weight: .semibold))
                } control: {
                    Picker("筛选", selection: $showAll) {
                        Text("只看待选").tag(false)
                        Text("全部").tag(true)
                    }
                    .pickerStyle(.segmented)
                }
                if ranked.isEmpty {
                    FREmptyState(
                        icon: "cube.box",
                        title: "还没有候选模型",
                        detail: "请先到模型中心添加服务商并刷新模型目录，再回到这里评估。",
                        actionTitle: "前往模型中心",
                        action: { coordinator.tab = 1 }
                    )
                } else {
                    ForEach(Array(displayed.indices), id: \.self) { index in
                        scoreRow(index: index, score: displayed[index])
                    }
                }
            }
        }
    }

    private var displayed: [RouteScore] {
        showAll ? ranked : ranked.filter { !$0.blocked }
    }

    private func scoreRow(index: Int, score: RouteScore) -> some View {
        let c = score.candidate
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("\(index + 1)")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(score.blocked ? Color.secondary : FRDesign.accent)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill((score.blocked ? Color.secondary : FRDesign.accent).opacity(0.12)))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(c.model.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        FRBadge(c.model.isFreeTier ? "免费" : "付费",
                                color: c.model.isFreeTier ? FRDesign.ok : FRDesign.accentCyan)
                        if score.blocked {
                            FRBadge("已屏蔽", color: Color.secondary, icon: "hand.raised")
                        }
                    }
                    Text(c.provider.name)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text(String(format: "%.3f", score.score))
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(score.blocked ? Color.secondary : FRDesign.accent)
                    .contentTransition(.numericText())
            }
            partBars(score.parts)
                .opacity(score.blocked ? 0.35 : 1)
            Text(score.reason)
                .font(.system(size: 10))
                .foregroundStyle(score.blocked ? Color.secondary : Color.secondary.opacity(0.85))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let br = score.blockReason, score.blocked {
                Text("屏蔽原因：\(br)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(FRDesign.err)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(.secondarySystemGroupedBackground).opacity(0.55)))
        .opacity(score.blocked ? 0.6 : 1)
    }

    private func partBars(_ parts: [(name: String, raw: Double, weighted: Double)]) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(parts.indices), id: \.self) { i in
                let part = parts[i]
                VStack(spacing: 3) {
                    ZStack(alignment: .bottom) {
                        Capsule().fill(Color(.systemFill)).frame(width: 13, height: 20)
                        Capsule()
                            .fill(FRDesign.accent.opacity(0.6))
                            .frame(width: 13, height: max(2, 20 * min(1, max(0, part.raw))))
                    }
                    Text(String(part.name.prefix(2)))
                        .font(.system(size: 8))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: 决策

    private var decisionSection: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("为什么这样选").font(.system(size: 13, weight: .semibold))
                Text(app.router.lastDecision.reason.isEmpty ? "尚未评估，点击「重新评估」开始。" : app.router.lastDecision.reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("当前生效权重（已归一化）").font(.system(size: 10)).foregroundStyle(.secondary)
                    ForEach(Array(app.router.activeWeights.breakdownLines.indices), id: \.self) { i in
                        let line = app.router.activeWeights.breakdownLines[i]
                        HStack {
                            Text(line.name).font(.system(size: 11))
                            Spacer()
                            Text(FRFormat.percent(line.value))
                                .font(.system(size: 11, weight: .semibold, design: .rounded))
                                .contentTransition(.numericText())
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground).opacity(0.55)))
                Button {
                    reevaluate()
                } label: {
                    Label("重新评估", systemImage: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FRDesign.accent))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .disabled(evaluating)
                .opacity(evaluating ? 0.6 : 1)
            }
        }
    }

    // MARK: 逻辑

    private var healthBinding: Binding<Double> {
        Binding(get: { wHealth }, set: { v in wHealth = v; pushWeights() })
    }
    private var freeBinding: Binding<Double> {
        Binding(get: { wFree }, set: { v in wFree = v; pushWeights() })
    }
    private var successBinding: Binding<Double> {
        Binding(get: { wSuccess }, set: { v in wSuccess = v; pushWeights() })
    }
    private var latencyBinding: Binding<Double> {
        Binding(get: { wLatency }, set: { v in wLatency = v; pushWeights() })
    }
    private var loadBinding: Binding<Double> {
        Binding(get: { wLoad }, set: { v in wLoad = v; pushWeights() })
    }
    private var capBinding: Binding<Double> {
        Binding(get: { wCap }, set: { v in wCap = v; pushWeights() })
    }

    private func pushWeights() {
        app.router.weightsOverride = RouteWeights(
            health: wHealth, freeQuota: wFree, successRate: wSuccess,
            latency: wLatency, load: wLoad, capability: wCap
        )
    }

    private func syncDraft() {
        let w = app.router.weightsOverride ?? app.router.mode.weights
        wHealth = w.health
        wFree = w.freeQuota
        wSuccess = w.successRate
        wLatency = w.latency
        wLoad = w.load
        wCap = w.capability
    }

    private func reevaluate() {
        evaluating = true
        ranked = app.router.decide(candidates: app.candidates(), request: nil).ranked
        evaluating = false
    }
}

/// 权重行数据（避免在 ForEach 中使用 tuple keypath）
private struct WeightItem: Identifiable {
    let key: String
    let title: String
    let color: Color
    let binding: Binding<Double>
    var id: String { title }
}
