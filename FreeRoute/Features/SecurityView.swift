import SwiftUI
import UIKit

/// 安全：API 密钥、网关 Token、钥匙串可用性与隐私声明
struct SecurityView: View {
    @Environment(AppState.self) private var app

    @State private var showToken = false
    @State private var tokenCopied = false
    @State private var pendingDelete: Provider?
    @State private var keychainState: Bool?
    @State private var keychainChecking = false

    var body: some View {
        ZStack {
            FRBackground()
            ScrollView {
                VStack(spacing: 12) {
                    keySection
                    tokenSection
                    keychainSection
                    privacySection
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("安全")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "删除密钥",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { p in
            Button("删除 \(p.name) 的密钥", role: .destructive) {
                app.deleteKey(provider: p)
            }
            Button("取消", role: .cancel) {}
        } message: { p in
            Text("将从系统钥匙串移除 \(p.name) 的 API 密钥，删除后不可恢复。")
        }
        .alert("已复制", isPresented: $tokenCopied) {
            Button("好", role: .cancel) {}
        } message: {
            Text("网关 Token 已复制到剪贴板。")
        }
        .task { checkKeychain() }
    }

    // MARK: - API 密钥

    private var keySection: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("API 密钥", systemImage: "key.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FRDesign.accent)
                Text("密钥仅写入系统钥匙串（Keychain），数据库与备份只保存引用，不存明文。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if app.providers.isEmpty {
                    Text("暂无已配置的服务商")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.providers) { p in
                        providerRow(p)
                        Divider().opacity(0.35)
                    }
                }
            }
        }
    }

    private func providerRow(_ p: Provider) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(p.name).font(.system(size: 12, weight: .semibold))
                Spacer()
                if let status = p.keys.first?.status {
                    FRBadge(status.label, color: statusColor(status))
                }
            }
            HStack(spacing: 8) {
                Text(app.maskedKey(for: p))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button(role: .destructive) {
                    pendingDelete = p
                } label: {
                    Text("删除密钥").font(.system(size: 11))
                }
                .disabled(p.keys.isEmpty)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusColor(_ status: KeyStatus) -> Color {
        switch status {
        case .healthy: return FRDesign.ok
        case .unauthorized, .forbidden: return FRDesign.err
        case .rateLimited: return FRDesign.warn
        case .disabled: return Color(.systemGray)
        case .unknown: return Color(.systemGray2)
        }
    }

    // MARK: - 网关 Token

    private var tokenSection: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("网关 Token", systemImage: "network")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FRDesign.accentCyan)
                Text(showToken ? app.gatewayToken : app.maskedGatewayToken)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 16) {
                    Button {
                        showToken.toggle()
                    } label: {
                        Label(showToken ? "隐藏" : "显示",
                              systemImage: showToken ? "eye.slash" : "eye")
                            .font(.system(size: 11))
                    }
                    Button {
                        copyToken()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    Spacer()
                }
                Text("上游 API 密钥永不下发给调用方；调用方须携带本 Token 才能访问网关。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyToken() {
        UIPasteboard.general.string = app.gatewayToken
        tokenCopied = true
    }

    // MARK: - 钥匙串可用性

    private var keychainSection: some View {
        FRCard {
            HStack(spacing: 8) {
                Image(systemName: keychainState == true
                      ? "checkmark.seal.fill"
                      : "lock.trianglebadge.exclamationmark")
                    .foregroundStyle(keychainState == true ? FRDesign.ok : FRDesign.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("钥匙串可用性").font(.system(size: 12, weight: .semibold))
                    Text("写入探针并读回验证，判断系统钥匙串是否可用。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if keychainChecking {
                    ProgressView()
                } else if let ok = keychainState {
                    Text(ok ? "可用" : "不可用")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(ok ? FRDesign.ok : FRDesign.err)
                } else {
                    Text("检测中")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func checkKeychain() {
        guard !keychainChecking else { return }
        keychainChecking = true
        let probe = "fr-selftest-\(UUID().uuidString)"
        let okSet = app.keychain.set(probe, for: "selftest")
        let okRead = app.keychain.get("selftest") == probe
        app.keychain.delete("selftest")
        keychainState = okSet && okRead
        keychainChecking = false
    }

    // MARK: - 隐私

    private var privacySection: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("隐私声明", systemImage: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(FRDesign.accent)
                Text("• 不收集遥测：无分析 SDK，数据不离开设备。")
                Text("• 数据只存本机：配置、模型、日志均在设备。")
                Text("• 备份默认不含明文密钥，密钥始终留在钥匙串。")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }
}
