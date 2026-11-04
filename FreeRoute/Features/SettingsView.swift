import SwiftUI
import ActivityKit

/// 设置：外观、路由、网关、监控、日志、安全、数据、关于
struct SettingsView: View {
    @Environment(AppState.self) private var app

    @State private var portText = ""
    @State private var showPortError = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                appearanceSection($app.settings)
                routingSection($app.settings)
                gatewaySection($app.settings)
                monitorSection($app.settings)
                logSection($app.settings)
                securitySection
                dataSection
                aboutSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { portText = "\(app.settings.gatewayPort)" }
            .onChange(of: app.settings) { _, _ in
                app.saveSettings()
            }
            .onChange(of: portText) { _, newValue in
                if let v = Int(newValue), (1...65535).contains(v) {
                    if app.settings.gatewayPort != v {
                        app.settings.gatewayPort = v
                    }
                    showPortError = false
                } else if !newValue.isEmpty {
                    showPortError = true
                }
            }
            .alert("端口无效", isPresented: $showPortError) {
                Button("好", role: .cancel) {}
            } message: {
                Text("端口须为 1–65535 的整数，请重新输入。")
            }
        }
    }

    // MARK: - 分组

    private func appearanceSection(_ settings: Binding<AppSettings>) -> some View {
        Section {
            Picker("主题", selection: Binding(
                get: { ThemeMode(rawValue: settings.wrappedValue.themeRaw) ?? .system },
                set: { newMode in
                    var s = settings.wrappedValue
                    s.themeRaw = newMode.rawValue
                    settings.wrappedValue = s
                }
            )) {
                ForEach(ThemeMode.allCases, id: \.self) { m in
                    Text(m.label).tag(m)
                }
            }
        } header: {
            Text("外观")
        } footer: {
            Text("动态字体：字号随系统「文字大小」自动调整。")
        }
    }

    private func routingSection(_ settings: Binding<AppSettings>) -> some View {
        Section {
            Picker("默认路由模式", selection: Binding(
                get: { RouterMode(rawValue: settings.wrappedValue.defaultRouterModeRaw) ?? .smartFree },
                set: { newMode in
                    var s = settings.wrappedValue
                    s.defaultRouterModeRaw = newMode.rawValue
                    settings.wrappedValue = s
                }
            )) {
                ForEach(RouterMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            Text(settings.wrappedValue.defaultRouterMode.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } header: {
            Text("路由")
        }
    }

    private func gatewaySection(_ settings: Binding<AppSettings>) -> some View {
        Section {
            HStack {
                Text("端口")
                Spacer()
                TextField("3000", text: $portText)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .foregroundStyle(showPortError ? FRDesign.err : Color.primary)
            }
            Toggle("局域网访问", isOn: settings.gatewayLANEnabled)
            Stepper(value: settings.maxConcurrentRequests, in: 1...16) {
                HStack {
                    Text("并发上限")
                    Spacer()
                    Text("\(settings.wrappedValue.maxConcurrentRequests)")
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("自动启动网关", isOn: settings.autoStartGateway)
        } header: {
            Text("网关")
        } footer: {
            Text("端口默认 3000；局域网开启后，同一 Wi-Fi 下的设备可访问本机网关。")
        }
    }

    private func monitorSection(_ settings: Binding<AppSettings>) -> some View {
        Section {
            Toggle("悬浮监控", isOn: settings.enableFloatingMonitor)
            Toggle("实时活动 Live Activity", isOn: settings.enableLiveActivity)
            if !liveActivitySupported {
                Label("当前系统未启用实时活动，可前往系统设置开启", systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("监控")
        } footer: {
            Text("悬浮监控为应用内实时小窗；实时活动显示在锁屏与灵动岛。")
        }
    }

    private func logSection(_ settings: Binding<AppSettings>) -> some View {
        Section {
            Stepper(value: settings.logRetentionDays, in: 1...90) {
                HStack {
                    Text("保留天数")
                    Spacer()
                    Text("\(settings.wrappedValue.logRetentionDays) 天")
                        .foregroundStyle(.secondary)
                }
            }
            Toggle("日志脱敏", isOn: settings.maskedLogs)
            NavigationLink { LogsView() } label: { Text("打开请求日志") }
            NavigationLink { StatisticsView() } label: { Text("打开统计中心") }
        } header: {
            Text("日志")
        } footer: {
            Text("日志仅存本机；开启脱敏后在展示时遮罩模型名与密钥。")
        }
    }

    private var securitySection: some View {
        Section {
            NavigationLink { SecurityView() } label: { Text("安全") }
        } header: {
            Text("安全")
        }
    }

    private var dataSection: some View {
        Section {
            NavigationLink { BackupView() } label: { Text("备份 / 恢复") }
        } header: {
            Text("数据")
        }
    }

    private var aboutSection: some View {
        Section {
            NavigationLink { AboutView() } label: { Text("关于 FreeRoute AI") }
            LabeledContent("版本", value: versionString)
        } header: {
            Text("关于")
        } footer: {
            Text("本地运行，不上传数据")
        }
    }

    // MARK: - 辅助

    private var liveActivitySupported: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private var versionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(v) (\(b))"
    }
}
