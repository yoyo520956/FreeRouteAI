import SwiftUI

/// 实时监控：PiP 规格布局 + 画中画控制 + 悬浮监控 + Live Activity
struct MonitorView: View {
    @Environment(AppState.self) private var app
    @Environment(AppCoordinator.self) private var coordinator
    @State private var pip = PiPController.shared

    var body: some View {
            ZStack {
                FRBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        pipLayoutCard
                        pipControlCard
                        liveActivityCard
                        detailCard
                        actionCard
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("实时监控")
            .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: PiP 规格布局

    private var pipLayoutCard: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 10) {
                HStack {
                    Text(FRFormat.time(ctx.date))
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                    Spacer()
                    Text(app.monitor.currentModel)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(FRDesign.accentCyan)
                        .lineLimit(1)
                }
                VStack(spacing: 0) {
                    Text("\(app.monitor.sessionTokens)")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .foregroundStyle(FRDesign.accent)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text("TOKENS")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 0) {
                    pipColumn(title: "吞吐", value: String(format: "%.1f tok/s", app.monitor.tokensPerSecond),
                              color: FRDesign.accent)
                    pipColumn(title: "时长", value: app.monitor.elapsedText(now: ctx.date),
                              color: .primary)
                    pipColumn(title: "网关",
                              value: app.monitor.gatewayRunning ? "运行中" : "已停止",
                              color: app.monitor.gatewayRunning ? FRDesign.ok : FRDesign.err)
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(FRDesign.accent.opacity(0.22), lineWidth: 1)
            )
        }
    }

    private func pipColumn(title: String, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: PiP 控制

    private var pipControlCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("系统画中画").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    FRBadge(pip.isSupported ? (pip.isActive ? "运行中" : "可用") : "设备不支持",
                            color: pip.isSupported ? (pip.isActive ? FRDesign.ok : FRDesign.accent) : FRDesign.err,
                            icon: pip.isActive ? "pip" : (pip.isSupported ? "pip.enter" : "xmark"))
                }
                Text(pip.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(pip.isActive ? FRDesign.ok : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if pip.isSupported {
                    Button {
                        pip.toggle(app)
                    } label: {
                        Label(pip.isActive ? "停止画中画" : "开始画中画",
                              systemImage: pip.isActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(pip.isActive ? FRDesign.err.opacity(0.16) : FRDesign.accent))
                            .foregroundStyle(pip.isActive ? FRDesign.err : .white)
                    }
                    .buttonStyle(.plain)
                    .disabled(pip.isStarting)
                } else {
                    Label("本机不支持系统画中画，可使用下方悬浮监控或锁屏 Live Activity。",
                          systemImage: "info.circle")
                        .font(.system(size: 11)).foregroundStyle(FRDesign.warn)
                }
                if pip.lastFrameCount > 0 {
                    Text("已渲染 \(pip.lastFrameCount) 帧").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Live Activity

    private var liveActivityCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("锁屏实时监控（Live Activity）").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    FRBadge(coordinator.liveActivity.isAvailable ? "可用" : "未授权",
                            color: coordinator.liveActivity.isAvailable ? FRDesign.ok : FRDesign.err,
                            icon: "lock.display")
                }
                Text(coordinator.liveActivity.statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(coordinator.liveActivity.isActive ? FRDesign.ok : .secondary)
                Button {
                    Task {
                        if coordinator.liveActivity.isActive {
                            await coordinator.liveActivity.stop()
                        } else {
                            await coordinator.liveActivity.start(for: app)
                        }
                    }
                } label: {
                    Label(coordinator.liveActivity.isActive ? "停止 Live Activity" : "开始 Live Activity",
                          systemImage: coordinator.liveActivity.isActive ? "stop.circle" : "play.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(coordinator.liveActivity.isActive ? FRDesign.err.opacity(0.16) : FRDesign.accentCyan.opacity(0.85)))
                        .foregroundStyle(coordinator.liveActivity.isActive ? FRDesign.err : .white)
                }
                .buttonStyle(.plain)
                .disabled(!coordinator.liveActivity.isAvailable)
            }
        }
    }

    // MARK: 详情

    private var detailCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("会话统计").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 8) {
                    FRBadge("进行中 \(app.monitor.activeRequests)", color: FRDesign.accent, icon: "arrow.up.forward")
                    FRBadge("完成 \(app.monitor.completedRequests)", color: FRDesign.ok, icon: "checkmark")
                    FRBadge("失败 \(app.monitor.failedRequests)", color: FRDesign.err, icon: "xmark")
                }
                HStack(spacing: 8) {
                    Text("服务商").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(app.monitor.currentProvider).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    if app.monitor.lastRequestDurationMs > 0 {
                        FRBadge("最近 \(FRFormat.ms(app.monitor.lastRequestDurationMs))", color: FRDesign.accentCyan, icon: "timer")
                    }
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(app.monitor.isStreaming ? FRDesign.ok : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                    Text(app.monitor.isStreaming ? "流式输出中" : "空闲")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Text(app.monitor.lastEventText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }

    // MARK: 操作

    private var actionCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("操作").font(.system(size: 13, weight: .semibold))
                Button {
                    coordinator.showFloatingMonitor.toggle()
                } label: {
                    HStack {
                        Label("悬浮监控", systemImage: "rectangle.on.rectangle")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Image(systemName: coordinator.showFloatingMonitor ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15))
                            .foregroundStyle(coordinator.showFloatingMonitor ? FRDesign.ok : Color.secondary.opacity(0.4))
                    }
                }
                .buttonStyle(.plain)
                Button {
                    app.monitor.resetSession()
                } label: {
                    Label("重置统计", systemImage: "arrow.counterclockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                        .foregroundStyle(FRDesign.accent)
                }
                .buttonStyle(.plain)
                Button {
                    coordinator.tab = 4
                } label: {
                    Label("跳转设置", systemImage: "gearshape")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FRDesign.accent.opacity(0.14)))
                        .foregroundStyle(FRDesign.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// 悬浮监控：可拖动、半透明材质、右上角全屏 overlay 子视图
struct FloatingMonitor: View {
    @Environment(AppState.self) private var app
    @Environment(AppCoordinator.self) private var coordinator
    @State private var offset: CGSize = .zero
    @State private var accumulated: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(app.monitor.currentModel)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer()
                Button {
                    coordinator.showFloatingMonitor = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.secondary.opacity(0.7))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭悬浮监控")
            }
            Text("\(FRFormat.compact(app.monitor.sessionTokens)) tok · \(String(format: "%.1f", app.monitor.tokensPerSecond))/s")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(FRDesign.accent)
                .lineLimit(1).minimumScaleFactor(0.6)
                .contentTransition(.numericText())
            HStack(spacing: 5) {
                FRStatusDot(color: app.monitor.gatewayRunning ? FRDesign.ok : FRDesign.err,
                            pulse: app.monitor.gatewayRunning)
                Text(app.monitor.gatewayRunning ? "网关运行中" : "网关已停止")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        // 悬浮监控窗：给可收缩区间，小屏（SE/放大显示）不会顶出屏幕边缘
        .frame(minWidth: 128, maxWidth: 176)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(FRDesign.accent.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
        .offset(offset)
        .gesture(
            DragGesture()
                .onChanged { value in
                    offset = CGSize(width: accumulated.width + value.translation.width,
                                    height: accumulated.height + value.translation.height)
                }
                .onEnded { value in
                    accumulated = CGSize(width: accumulated.width + value.translation.width,
                                         height: accumulated.height + value.translation.height)
                    offset = accumulated
                }
        )
        .padding(.top, 8)
        .padding(.trailing, 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: offset)
    }
}
