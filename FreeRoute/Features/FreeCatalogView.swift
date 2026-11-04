import SwiftUI

/// 全球免费 AI 服务商目录（额度信息来自官方文档，带最后验证日期）
struct FreeCatalogView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var message: String?
    @State private var showMessage = false
    @State private var onlyFree = true

    var entries: [FreeProviderInfo] {
        onlyFree ? ProviderCatalog.freeProviders.filter { $0.freeTier } : ProviderCatalog.freeProviders
    }

    var body: some View {
        NavigationStack {
            ZStack {
                FRBackground()
                ScrollView {
                    VStack(spacing: 12) {
                        noticeCard
                        Toggle(isOn: $onlyFree) {
                            Text("只看待免费额度").font(.system(size: 13))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.secondarySystemGroupedBackground)))
                        ForEach(entries, id: \.name) { info in
                            FreeCatalogCard(info: info) { add(info) } openDocs: {
                                if let url = URL(string: info.signupURL) { openURL(url) }
                            }
                        }
                        Text("共 \(entries.count) 家。额度、限流与地区政策随时会变，注册前请打开官网核对。")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                    }
                    .padding(.horizontal, 12).padding(.bottom, 20)
                }
            }
            .navigationTitle("免费服务商目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .alert("提示", isPresented: $showMessage) {
                Button("好", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
        }
    }

    private var noticeCard: some View {
        FRCard {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(FRDesign.warn).font(.system(size: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("这是「免费额度」目录，不是无限免费").font(.system(size: 13, weight: .semibold))
                    Text("免费额度由各家服务商自己决定，通常有每日/每分钟限流，部分需要信用卡或仅限部分地区。本 App 不会绕过任何配额与账户限制。")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func add(_ info: FreeProviderInfo) {
        if app.providers.contains(where: {
            $0.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
            info.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }) {
            message = "\(info.name) 已在你的服务商列表中，去「服务商管理」填 API Key 即可"
            showMessage = true
            return
        }
        var p = info.toProvider(kind: ProviderCatalog.kind(for: info))
        p.notes = info.quotaNote
        app.addProvider(p)
        message = "已添加 \(info.name)。请在服务商管理里填入你自己的 API Key"
        showMessage = true
    }
}

private struct FreeCatalogCard: View {
    let info: FreeProviderInfo
    let onAdd: () -> Void
    let openDocs: () -> Void

    var body: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(info.name).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    FRBadge(info.protocolType.displayName, color: FRDesign.accent)
                }
                HStack(spacing: 6) {
                    FRBadge(info.freeTier ? "有免费额度" : "需付费",
                           color: info.freeTier ? FRDesign.ok : FRDesign.warn,
                           icon: info.freeTier ? "gift" : "creditcard")
                    FRBadge("需注册", color: FRDesign.accentCyan, icon: "person.badge.plus")
                    FRBadge("地区限制", color: FRDesign.warn, icon: "globe")
                }
                grid
                Text("额度信息最后验证：\(info.lastVerifiedISO)")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Button(action: onAdd) {
                        Text("添加到我的服务商")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(FRDesign.accent))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Button(action: openDocs) {
                        Text("打开注册页")
                            .font(.system(size: 12, weight: .medium))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(FRDesign.accent.opacity(0.14)))
                            .foregroundStyle(FRDesign.accent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("免费额度", info.quotaNote)
            row("限流", info.rateLimitNote)
            row("地区", info.regionNote)
            row("注册要求", info.registrationNote)
            row("账户要求", info.accountNote)
            row("免费模型", info.freeModelsNote)
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(Color(.tertiarySystemGroupedBackground).opacity(0.7)))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(k).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .frame(width: 56, alignment: .leading)
            Text(v).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}
