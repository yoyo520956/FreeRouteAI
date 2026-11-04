import SwiftUI

/// 关于：应用信息、许可、第三方归属与诚实声明
struct AboutView: View {
    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }
    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        ZStack {
            FRBackground()
            ScrollView {
                VStack(spacing: 12) {
                    headerCard
                    factsCard
                    linksCard
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - 头部

    private var headerCard: some View {
        FRCard {
            VStack(spacing: 10) {
                FRRoutingGlyph(size: 88)
                Text("FreeRoute AI")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("自由路由")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text("AI Gateway & Smart Router")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(FRDesign.accent)
                Text("One Gateway. Every Model. Smarter Routing.")
                    .font(.system(size: 11, design: .italic))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 事实与声明

    private var factsCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("版本 \(version) (\(build))")
                    .font(.system(size: 13, weight: .semibold))
                Text("开源许可：本项目使用 Apple 官方框架（SwiftUI / SwiftData / Charts / ActivityKit 等），无第三方依赖。")
                Text("第三方归属：各 AI 服务商名称与商标归其各自所有者所有；本项目与其无隶属关系。")
                Text("诚实声明：本 App 不绕过任何服务商配额与账户限制；免费额度信息以各服务商官网为准。")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    // MARK: - 服务商官网

    private var linksCard: some View {
        FRCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("服务商官网")
                    .font(.system(size: 12, weight: .semibold))
                ForEach(ProviderCatalog.freeProviders) { info in
                    if let url = URL(string: info.homepage) {
                        Link(destination: url) {
                            HStack {
                                Text(info.name)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.primary)
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(FRDesign.accent)
                            }
                        }
                        Divider().opacity(0.3)
                    }
                }
            }
        }
    }
}
