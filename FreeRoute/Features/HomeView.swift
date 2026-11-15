import SwiftUI

/// 首页：AI 网关控制中心
struct HomeView: View {
    @Environment(AppState.self) private var app
    @Environment(AppCoordinator.self) private var coordinator

    @State private var starting = false
    @State private var showGateway = false
    @State private var testRunning = false
    @State private var testResult: String?
    @State private var showTestAlert = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            ZStack {
                FRBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        gatewayCard
                        metricsCard
                        currentCard
                        quickActions
                        recentCard
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 18)
                }
            }
            .navigationTitle("AI 网关控制中心")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { MonitorView() } label: {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .accessibilityLabel("打开实时监控")
                }
            }
            .task { app.statistics.reload() }
            .refreshable {
                app.refreshLogs()
                app.statistics.reload()
                app.gateway.refreshStatus()
            }
            .alert("自检结果", isPresented: $showTestAlert) {
                Button("好", role: .cancel) {}
            } message: {
                Text(testResult ?? "无结果")
            }
        }
    }

    // MARK: 网关控制

    private var gatewayCard: some View {
        FRCard {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill((app.gateway.status.isRunning ? FRDesign.ok : FRDesign.err).opacity(0.14))
                        .frame(width: 52, height: 52)
                    Image(systemName: app.gateway.status.isRunning ? "network" : "network.slash")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(app.gateway.status.isRunning ? FRDesign.ok : FRDesign.err)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(app.gateway.status.isRunning ? "网关运行中" : "网关已停止")
                        .font(.system(size: 17, weight: .bold))
                    Text(app.gateway.status.isRunning
                         ? app.gateway.status.loopbackAddress
                         : "端口 \(app.settings.gatewayPort) · 局域网\(app.settings.gatewayLANEnabled ? "已开启" : "关闭")")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button {
                    Task {
                        starting = true
                        if app.gateway.status.isRunning { app.gateway.stop() }
                        else { await app.gateway.start() }
                        starting = false
                        app.statistics.reload()
                    }
                } label: {
                    if starting {
                        ProgressView().frame(width: 56, height: 28)
                    } else {
                        Text(app.gateway.status.isRunning ? "停止" : "启动")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(Capsule().fill(app.gateway.status.isRunning ? Color.red.opacity(0.15) : FRDesign.accent))
                            .foregroundStyle(app.gateway.status.isRunning ? FRDesign.err : .white)
                    }
                }
                .buttonStyle(.plain)
                .disabled(starting)
            }
            if let err = app.gateway.status.lastError {
                Text(err).font(.system(size: 11)).foregroundStyle(FRDesign.err).padding(.top, 6)
            }
            HStack(spacing: 8) {
                FRBadge("本机 \(app.gateway.status.connectionCount) 连接", color: FRDesign.accent, icon: "cable.connector")
                FRBadge("累计 \(app.gateway.status.totalRequests) 请求", color: FRDesign.accentCyan, icon: "number")
                if app.gateway.status.lanEnabled {
                    FRBadge("局域网可达", color: FRDesign.warn, icon: "wifi")
                }
            }
            .padding(.top, 10)
        }
    }

    // MARK: 今日指标

    private var metricsCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                FRMetric("今日请求", value: FRFormat.compact(app.statistics.todayRequests), icon: "bolt.horizontal", tint: FRDesign.accent)
                FRMetric("成功率", value: app.statistics.todayRequests == 0 ? "—" : FRFormat.percent(app.statistics.todaySuccessRate),
                         icon: "checkmark.seal", tint: FRDesign.ok)
            }
            HStack(spacing: 10) {
                FRMetric("Token 用量", value: FRFormat.compact(app.statistics.todayTokens), icon: "number.square", tint: FRDesign.accentCyan)
                FRMetric("平均响应", value: app.statistics.avgLatencyMs == 0 ? "—" : FRFormat.ms(app.statistics.avgLatencyMs),
                         icon: "timer", tint: FRDesign.warn)
            }
        }
    }

    // MARK: 当前服务商 / 模型

    private var currentCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text("当前调度").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    FRBadge(app.router.mode.rawValue, color: FRDesign.accent, icon: "arrow.triangle.branch")
                }
                HStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(app.monitor.currentProvider).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text("→").foregroundStyle(.secondary)
                    Text(app.monitor.currentModel).font(.system(size: 13, design: .monospaced)).lineLimit(1)
                }
                Text(app.router.lastDecision.reason.isEmpty ? "尚未发起请求，路由将在首次请求时评估" : app.router.lastDecision.reason)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    FRBadge("\(app.providers.count) 服务商", color: FRDesign.accent)
                    FRBadge("\(app.models.count) 模型", color: FRDesign.accentCyan)
                    FRBadge("\(app.providers.filter { $0.hasUsableKey }.count) 个密钥就绪", color: FRDesign.ok)
                    if app.router.totalSwitches > 0 {
                        FRBadge("切换 \(app.router.totalSwitches) 次", color: FRDesign.warn)
                    }
                }
            }
        }
    }

    // MARK: 快捷操作

    private var quickActions: some View {
        HStack(spacing: 10) {
            quickButton("刷新全部模型", "arrow.clockwise", FRDesign.accent) {
                Task {
                    let reports = await app.refreshAllEnabled()
                    let added = reports.reduce(0) { $0 + $1.added }
                    let failed = reports.compactMap { $0.error }.first
                    testResult = failed.map { "部分服务商刷新失败：\($0)（共新增 \(added) 个模型）" }
                        ?? "模型刷新完成，共新增/更新 \(added) 个模型"
                    showTestAlert = true
                }
            }
            quickButton("路由诊断", "stethoscope", FRDesign.accentCyan) {
                let cands = app.candidates()
                let decision = app.router.decide(candidates: cands, request: nil)
                testResult = decision.chosen.map { "首选：\($0.model.displayName)（\($0.provider.name)）\n\(decision.reason)" }
                    ?? "无可用候选：\(decision.reason)"
                showTestAlert = true
            }
            quickButton("连通自检", "wifi", FRDesign.ok) {
                guard let p = app.providers.first(where: { $0.hasUsableKey }) else {
                    testResult = "没有已配置密钥的服务商，请先在模型 → 服务商管理里添加 API Key"
                    showTestAlert = true
                    return
                }
                testRunning = true
                Task {
                    let r = await app.probe(provider: p)
                    testResult = "\(p.name)：\(r.ok ? "可用" : "失败")，\(FRFormat.ms(r.latencyMs))\(r.httpStatus.map { "，HTTP \($0)" } ?? "")\n\(r.message)"
                    testRunning = false
                    showTestAlert = true
                }
            }
        }
    }

    private func quickButton(_ title: String, _ icon: String, _ tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 15, weight: .medium))
                Text(title).font(.system(size: 10, weight: .medium)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(tint.opacity(0.12)))
            .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: 最近请求

    private var recentCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近请求").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    NavigationLink { LogsView() } label: {
                        Text("全部").font(.system(size: 12)).foregroundStyle(FRDesign.accent)
                    }
                }
                if app.recentLogs.isEmpty {
                    FREmptyState(icon: "list.bullet.rectangle", title: "还没有请求记录",
                                 detail: "启动网关后，从其他设备调用 /v1/chat/completions，或点击「连通自检」，这里就会出现记录。")
                        .padding(.vertical, 14)
                } else {
                    ForEach(app.recentLogs.prefix(5)) { log in
                        HStack(spacing: 8) {
                            FRStatusDot(color: log.ok ? FRDesign.ok : FRDesign.err)
                            Text(FRFormat.time(log.timestamp)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                            Text(log.modelID).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            if log.switched { FRBadge("切换", color: FRDesign.warn) }
                            Text(FRFormat.compact(log.totalTokens)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text(FRFormat.ms(log.durationMs)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }
}
