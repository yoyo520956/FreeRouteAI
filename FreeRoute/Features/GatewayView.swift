import SwiftUI

/// 本地 / 局域网网关：启停、地址、端口、鉴权 Token、接口清单
struct GatewayView: View {
    @Environment(AppState.self) private var app

    @State private var portText = ""
    @State private var portError: String?
    @State private var lanDraft = false
    @State private var showLANConfirm = false
    @State private var showToken = false
    @State private var showRegenConfirm = false
    @State private var copiedKey: String?
    @State private var notice: String?

    var body: some View {
        NavigationStack {
            ZStack {
                FRBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        statusCard
                        addressCard
                        configCard
                        statsCard
                        tokenCard
                        endpointsCard
                        footnoteCard
                        if let notice {
                            Text(notice)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(FRDesign.ok)
                                .frame(maxWidth: .infinity)
                                .padding(9)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(FRDesign.ok.opacity(0.12)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .refreshable { app.gateway.refreshStatus() }
            }
            .navigationTitle("网关")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        app.gateway.refreshStatus()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新状态")
                }
            }
            .task {
                portText = "\(app.settings.gatewayPort)"
                lanDraft = app.settings.gatewayLANEnabled
            }
            .alert("开启局域网访问", isPresented: $showLANConfirm) {
                Button("取消", role: .cancel) { lanDraft = false }
                Button("开启") {
                    lanDraft = true
                    applyLAN(true)
                }
            } message: {
                Text("局域网访问会把本机网关暴露给同一 Wi-Fi 下的所有设备。任何客户端都必须携带网关 Token 才能调用接口，请确保 Token 不被泄露。")
            }
            .alert("重新生成 Token", isPresented: $showRegenConfirm) {
                Button("取消", role: .cancel) {}
                Button("生成") {
                    app.keychain.delete("gateway/token")
                    _ = app.gatewayToken
                    showToken = false
                    notify("已生成新 Token，旧 Token 即刻失效")
                }
            } message: {
                Text("生成后，所有使用旧 Token 的客户端将立即收到 401。确定继续？")
            }
        }
    }

    // MARK: 状态卡

    private var statusCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill((app.gateway.status.isRunning ? FRDesign.ok : FRDesign.err).opacity(0.14))
                            .frame(width: 52, height: 52)
                        FRStatusDot(color: app.gateway.status.isRunning ? FRDesign.ok : FRDesign.err,
                                    pulse: app.gateway.status.isRunning)
                            .scaleEffect(2.4)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.gateway.status.isRunning ? "网关运行中" : "网关已停止")
                            .font(.system(size: 17, weight: .bold))
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(uptimeText(now: ctx.date))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .contentTransition(.numericText())
                        }
                    }
                    Spacer()
                    Button {
                        if app.gateway.status.isRunning {
                            app.gateway.stop()
                        } else {
                            Task {
                                await app.gateway.start()
                                app.gateway.refreshStatus()
                            }
                        }
                    } label: {
                        if app.gateway.isStarting {
                            ProgressView().frame(width: 56, height: 28)
                        } else {
                            Text(app.gateway.status.isRunning ? "停止" : "启动")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Capsule().fill(app.gateway.status.isRunning ? FRDesign.err.opacity(0.16) : FRDesign.accent))
                                .foregroundStyle(app.gateway.status.isRunning ? FRDesign.err : .white)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(app.gateway.isStarting)
                }
                if let err = app.gateway.status.lastError {
                    Label(err, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11))
                        .foregroundStyle(FRDesign.err)
                }
            }
        }
    }

    private func uptimeText(now: Date) -> String {
        guard let started = app.gateway.status.startedAt else {
            return app.gateway.status.isRunning ? "正在建立连接…" : "未运行"
        }
        let s = Int(max(0, now.timeIntervalSince(started)))
        return String(format: "已运行 %02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }

    // MARK: 地址

    private var addressCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("访问地址").font(.system(size: 13, weight: .semibold))
                addressRow(title: "本机（回环）", value: app.gateway.status.loopbackAddress,
                           icon: "iphone", color: FRDesign.accent)
                addressRow(title: "局域网", value: app.gateway.status.lanAddress,
                           icon: "wifi", color: FRDesign.accentCyan)
                if app.gateway.status.lanAddress == nil {
                    Text(app.settings.gatewayLANEnabled
                         ? "已开启局域网，但暂未探测到 IP（请检查 Wi-Fi 连接）。"
                         : "局域网访问未开启。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func addressRow(title: String, value: String?, icon: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                Text(value ?? "—").font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer()
            if let value {
                Button {
                    copy(value, key: "addr-" + title)
                } label: {
                    Image(systemName: copiedKey == "addr-" + title ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(copiedKey == "addr-" + title ? FRDesign.ok : FRDesign.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制\(title)地址")
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground).opacity(0.55)))
    }

    // MARK: 配置

    private var configCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("配置").font(.system(size: 13, weight: .semibold))
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("端口").font(.system(size: 12, weight: .medium))
                        TextField("3000", text: $portText)
                            .keyboardType(.numberPad)
                            .font(.system(size: 13, design: .monospaced))
                            .frame(width: 110)
                            .padding(7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemGroupedBackground)))
                            .onChange(of: portText) { _, _ in validatePort() }
                    }
                    Spacer()
                    if let e = portError {
                        Text(e).font(.system(size: 10)).foregroundStyle(FRDesign.err)
                            .multilineTextAlignment(.trailing)
                    }
                }
                if app.gateway.status.isRunning && app.settings.gatewayPort != app.gateway.status.port {
                    HStack(spacing: 8) {
                        Label("端口修改后需重启生效", systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11))
                            .foregroundStyle(FRDesign.warn)
                        Spacer()
                        Button {
                            Task { await app.gateway.restart() }
                        } label: {
                            Text("立即重启")
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(FRDesign.warn.opacity(0.16)))
                                .foregroundStyle(FRDesign.warn)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "network.badge.shield.half.filled").font(.system(size: 12)).foregroundStyle(FRDesign.warn).frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("局域网访问").font(.system(size: 12, weight: .medium))
                        Text("暴露到同一 Wi-Fi，必须使用 Token 鉴权")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: lanToggle).labelsHidden()
                }
            }
        }
    }

    private var lanToggle: Binding<Bool> {
        Binding(
            get: { lanDraft },
            set: { newValue in
                if newValue {
                    lanDraft = true
                    showLANConfirm = true
                } else {
                    lanDraft = false
                    applyLAN(false)
                }
            }
        )
    }

    private func validatePort() {
        portText = portText.filter { $0.isNumber }.prefix(5).description
        guard !portText.isEmpty else { portError = nil; return }
        if let v = Int(portText) {
            if (1024...65535).contains(v) {
                portError = nil
                if v != app.settings.gatewayPort {
                    app.settings.gatewayPort = v
                    app.saveSettings()
                }
            } else {
                portError = "端口需在 1024–65535 之间"
            }
        } else {
            portError = "请输入数字"
        }
    }

    private func applyLAN(_ enabled: Bool) {
        app.settings.gatewayLANEnabled = enabled
        app.saveSettings()
        if enabled {
            app.gateway.refreshStatus()
            notify("局域网已开启：同一 Wi-Fi 客户端可用 Token 访问")
        }
    }

    // MARK: 统计

    private var statsCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("运行统计").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 10) {
                    FRMetric("当前连接", value: "\(app.gateway.status.connectionCount)", icon: "cable.connector", tint: FRDesign.accent)
                    FRMetric("累计请求", value: FRFormat.compact(app.gateway.status.totalRequests), icon: "number", tint: FRDesign.accentCyan)
                }
                if let started = app.gateway.status.startedAt {
                    Text("启动于 \(FRFormat.dateTime(started))").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Token

    private var tokenCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("网关 Token").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button {
                        showToken.toggle()
                    } label: {
                        Label(showToken ? "隐藏" : "显示", systemImage: showToken ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(FRDesign.accent)
                }
                HStack(spacing: 8) {
                    Text(showToken ? app.gateway.token : app.gateway.maskedToken)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button {
                        copy(app.gateway.token, key: "token")
                    } label: {
                        Image(systemName: copiedKey == "token" ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 13))
                            .foregroundStyle(copiedKey == "token" ? FRDesign.ok : FRDesign.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("复制 Token")
                    Button {
                        showRegenConfirm = true
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 13))
                            .foregroundStyle(FRDesign.warn)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("重新生成 Token")
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground).opacity(0.55)))
                Text("所有请求都必须携带 Authorization: Bearer <Token>，未授权访问将返回 401。")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 接口清单

    private var endpointsCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("接口清单").font(.system(size: 13, weight: .semibold))
                endpointRow(method: "GET", path: "/v1/models", color: FRDesign.ok,
                            curl: curl(method: "GET", path: "/v1/models"))
                endpointRow(method: "POST", path: "/v1/chat/completions", color: FRDesign.accent,
                            curl: curl(method: "POST", path: "/v1/chat/completions",
                                       body: "{\"model\":\"gpt-4o\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"))
                endpointRow(method: "POST", path: "/v1/responses", color: FRDesign.accentCyan,
                            curl: curl(method: "POST", path: "/v1/responses",
                                       body: "{\"model\":\"gpt-4o\",\"input\":\"hi\"}"))
                endpointRow(method: "POST", path: "/v1/embeddings", color: Color.purple,
                            curl: curl(method: "POST", path: "/v1/embeddings",
                                       body: "{\"model\":\"text-embedding-3-small\",\"input\":\"hi\"}"))
            }
        }
    }

    private func endpointRow(method: String, path: String, color: Color, curl: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                FRBadge(method, color: color)
                Text(path).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer()
                Button {
                    copy(curl, key: "curl-" + path)
                } label: {
                    Image(systemName: copiedKey == "curl-" + path ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 12))
                        .foregroundStyle(copiedKey == "curl-" + path ? FRDesign.ok : FRDesign.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("复制 curl 示例")
            }
            Text(curl)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground).opacity(0.55)))
    }

    private func curl(method: String, path: String, body: String? = nil) -> String {
        let port = app.settings.gatewayPort
        let base = "http://127.0.0.1:\(port)\(path)"
        var cmd = "curl -X \(method) -H \"Authorization: Bearer \(app.gateway.token)\""
        if body != nil { cmd += " -H \"Content-Type: application/json\"" }
        if let body {
            cmd += " -d '\(body)'"
        }
        return cmd + " " + base
    }

    // MARK: 底部提示

    private var footnoteCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 6) {
                Label("上游密钥安全", systemImage: "lock.shield")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(FRDesign.ok)
                Text("你的上游服务商 API Key 永远不会通过本网关暴露给客户端。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Label("鉴权", systemImage: "checkmark.shield")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(FRDesign.ok)
                Text("未携带或携带错误 Token 的请求会被 401 拒绝，局域网与本机一致。")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 复制

    private func copy(_ text: String, key: String) {
        UIPasteboard.general.string = text
        copiedKey = key
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if copiedKey == key { copiedKey = nil }
        }
    }

    private func notify(_ message: String) {
        notice = message
        Task {
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if notice == message { notice = nil }
        }
    }
}
