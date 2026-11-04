import SwiftUI
import WidgetKit
import ActivityKit

@main
struct FreeRouteWidgetBundle: WidgetBundle {
    var body: some Widget {
        FRMonitorLiveActivity()
    }
}

/// 锁屏 / 灵动岛实时监控（PiP 的合规替代路径）
struct FRMonitorLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: FRMonitorAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("FreeRoute").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        Text(context.state.model)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(String(format: "%.0f tok/s", context.state.tokensPerSecond))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(.cyan)
                        Text(context.state.gatewayRunning ? "网关运行中" : "网关已停止")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("\(context.state.tokens) tokens")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 6) {
                        Circle().fill(context.state.streaming ? Color.green : Color.gray).frame(width: 6, height: 6)
                        Text(context.state.streaming ? "正在接收流式响应" : "空闲")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                        Spacer()
                        Text(context.state.gatewayURL).font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(.tertiary).lineLimit(1)
                    }
                    .padding(.horizontal, 2)
                }
            } compactLeading: {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(.cyan)
            } compactTrailing: {
                Text(Self.compact(context.state.tokens))
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.cyan)
            } minimal: {
                Image(systemName: "arrow.triangle.branch")
            }
            .keylineTint(.cyan)
        }
    }

    static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}

struct LockScreenView: View {
    let context: ActivityViewContext<FRMonitorAttributes>

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Label("自由路由", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.cyan)
                Spacer()
                Text(context.state.model)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(context.state.tokens)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                Text("tokens").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f tok/s", context.state.tokensPerSecond))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.cyan)
                    HStack(spacing: 4) {
                        Circle().fill(context.state.streaming ? Color.green : Color.gray)
                            .frame(width: 5, height: 5)
                        Text(context.state.gatewayRunning ? "网关运行中" : "网关已停止")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(12)
        .activityBackgroundTint(Color(red: 0.043, green: 0.063, blue: 0.11))
        .activitySystemActionForegroundColor(.white)
    }
}
