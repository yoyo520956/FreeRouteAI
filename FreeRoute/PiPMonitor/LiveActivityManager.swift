import Foundation
import ActivityKit
import Observation

/// Live Activity（灵动岛/锁屏实时监控）——PiP 不可用时的官方替代路径
@MainActor
@Observable
public final class LiveActivityManager {
    public private(set) var isAvailable: Bool = ActivityAuthorizationInfo(for: FRMonitorAttributes.self).areActivitiesEnabled
    public private(set) var isActive: Bool = false
    public private(set) var statusText: String = "未启用"
    private var activity: Activity<FRMonitorAttributes>?
    private var refreshTask: Task<Void, Never>?

    public init() {
        refresh()
    }

    public func refresh(for app: AppState?) {
        isAvailable = ActivityAuthorizationInfo(for: FRMonitorAttributes.self).areActivitiesEnabled
        activity = Activity<FRMonitorAttributes>.activities.first
        isActive = activity != nil
        if let activity {
            statusText = isActive ? "监控中：\(activity.contentState.model)" : "未启用"
        } else {
            statusText = isAvailable ? "可开启" : "系统未授权 Live Activity"
        }
        guard isActive, let app else { return }
        Task { [weak app] in
            await update(state: Self.state(from: app))
        }
    }

    public static func state(from app: AppState?) -> FRMonitorAttributes.ContentState {
        guard let app else {
            return FRMonitorAttributes.ContentState(model: "—", tokens: 0, tokensPerSecond: 0,
                                                    streaming: false, gatewayRunning: false)
        }
        let st = app.gateway.status
        return FRMonitorAttributes.ContentState(
            model: app.monitor.currentModel,
            tokens: app.monitor.sessionTokens,
            tokensPerSecond: app.monitor.tokensPerSecond,
            streaming: app.monitor.isStreaming,
            gatewayRunning: st.isRunning,
            gatewayURL: (st.lanEnabled ? st.lanAddress : nil) ?? st.loopbackAddress
        )
    }

    public func start(for app: AppState?) async {
        guard ActivityAuthorizationInfo(for: FRMonitorAttributes.self).areActivitiesEnabled else {
            statusText = "请到 系统设置 → 自由路由 → Live Activity 打开"
            isAvailable = false
            return
        }
        #if os(iOS)
        guard ActivityAuthorizationInfo(for: FRMonitorAttributes.self).areActivitiesEnabled else {
            statusText = "系统未授权 Live Activity"
            return
        }
        #endif
        let attrs = FRMonitorAttributes()
        do {
            let activity = try Activity.request(attributes: attrs,
                                                content: .init(state: Self.state(from: app), staleDate: nil),
                                                pushType: nil)
            self.activity = activity
            isActive = true
            statusText = "监控中"
            startAutoRefresh(app: app)
        } catch {
            statusText = "启动失败：\(error.localizedDescription)"
        }
    }

    public func update(state: FRMonitorAttributes.ContentState) async {
        guard let activity else { return }
        await activity.update(ActivityContent(state: state, staleDate: nil))
    }

    public func stop() async {
        guard let activity else { return }
        await activity.end(nil, dismissalPolicy: .immediate)
        self.activity = nil
        isActive = false
        statusText = "已停止"
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// 每秒把最新监控数据推给锁屏（只在激活时跑）
    public func startAutoRefresh(app: AppState?) {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor [weak self, weak app] in
            while !Task.isCancelled {
                guard let self, let app, self.isActive else { return }
                await self.update(state: Self.state(from: app))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}
