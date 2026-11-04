import SwiftUI
import SwiftData

@main
struct FreeRouteApp: App {
    @State private var app = AppState.shared
    @State private var coordinator = AppCoordinator()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(coordinator)
                .environment(app.statistics)
                .tint(FRDesign.accent)
                .preferredColorScheme(app.settings.theme.colorScheme)
                .onAppear { coordinator.attach(app) }
                .task { await app.bootstrap() }
                .onOpenURL { url in coordinator.handle(url) }
        }
    }
}

/// 全局协调器：截图模式、悬浮监控、PiP、Live Activity 生命周期
@MainActor
@Observable
final class AppCoordinator {
    var tab: Int = 0
    var showFloatingMonitor = false
    var pipActive = false
    weak var app: AppState?
    let liveActivity = LiveActivityManager()

    func attach(_ app: AppState) {
        self.app = app
        app.gateway.onLog = { [weak self] msg in self?.appendSystem(msg) }
        app.statistics.bind(app)
        NotificationCenter.default.addObserver(forName: ScenePhaseObserver.didEnterBackground, object: nil, queue: .main) { _ in
            Task { @MainActor in self.liveActivity.refresh(for: self?.app) }
        }
    }

    func appendSystem(_ message: String) {
        guard let app else { return }
        Task { await app.appendLog(model: "系统", provider: "网关", ms: 0, usage: nil, status: 200, ok: true, switched: false, errorNote: message) }
    }

    /// freeroute://screenshot/3 用于云端模拟器逐屏截图
    func handle(_ url: URL) {
        guard url.scheme == "freeroute" else { return }
        if url.host == "screenshot", let n = Int(url.lastPathComponent) {
            app?.screenshotTarget = n
        }
    }
}

enum ScenePhaseObserver {
    static let didEnterBackground = Notification.Name("freeroute.didEnterBackground")
    static let willEnterForeground = Notification.Name("freeroute.willEnterForeground")
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        @Bindable var app = app
        TabView(selection: $coordinator.tab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "square.grid.2x2.fill") }.tag(0)
            ModelsHubView()
                .tabItem { Label("模型", systemImage: "cube.box.fill") }.tag(1)
            SmartRouterView()
                .tabItem { Label("路由", systemImage: "arrow.triangle.branch") }.tag(2)
            GatewayView()
                .tabItem { Label("网关", systemImage: "network") }.tag(3)
            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(4)
        }
        .overlay(alignment: .topTrailing) {
            if coordinator.showFloatingMonitor { FloatingMonitor() }
        }
        .overlay { if app.isBootstrapping { LaunchSplash() } }
        // 不强制字号：跟随用户的动态字体设置（SE3 小屏由各页面的 minimumScaleFactor 兜底）
    }
}

private struct LaunchSplash: View {
    var body: some View {
            ZStack {
            FRBackground()
            VStack(spacing: 18) {
                FRRoutingGlyph(size: 96)
                Text("FreeRoute AI").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("One Gateway. Every Model. Smarter Routing.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                ProgressView().padding(.top, 8)
            }
        }
    }
}
