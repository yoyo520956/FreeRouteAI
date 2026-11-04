import SwiftUI

/// FreeRoute AI 品牌视觉系统（Apple 原生质感：深蓝黑 + 电光蓝 + 青色）
public enum FRDesign {
    // 主色：电光蓝；辅色：青色
    public static let accent = Color(red: 0.23, green: 0.52, blue: 1.0)
    public static let accentCyan = Color(red: 0.20, green: 0.85, blue: 0.92)
    public static let ok = Color(red: 0.20, green: 0.78, blue: 0.45)
    public static let warn = Color(red: 1.0, green: 0.62, blue: 0.15)
    public static let err = Color(red: 1.0, green: 0.35, blue: 0.35)

    /// 深色模式：深蓝黑
    public static let deepBG = Color(red: 0.043, green: 0.063, blue: 0.11)
    public static let deepCard = Color(red: 0.086, green: 0.11, blue: 0.176)

    public static let corner: CGFloat = 14

    public static func glow(_ color: Color, radius: CGFloat = 10) -> some View {
        color.opacity(0.35).blur(radius: radius)
    }
}

/// 渐变主背景（浅色用系统底色，深色用深蓝黑）
public struct FRBackground: View {
    @Environment(\.colorScheme) private var scheme
    public init() {}
    public var body: some View {
        Group {
            if scheme == .dark {
                LinearGradient(colors: [FRDesign.deepBG,
                                        Color(red: 0.055, green: 0.075, blue: 0.13),
                                        Color(red: 0.03, green: 0.05, blue: 0.09)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Color(.systemGroupedBackground)
            }
        }
        .ignoresSafeArea()
    }
}

/// 统一卡片
public struct FRCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    private let padding: CGFloat
    private let content: Content
    public init(padding: CGFloat = 14, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }
    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: FRDesign.corner, style: .continuous)
                    .fill(scheme == .dark ? FRDesign.deepCard : Color(.secondarySystemGroupedBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: FRDesign.corner, style: .continuous)
                    .strokeBorder(scheme == .dark ? Color.white.opacity(0.07) : Color.black.opacity(0.06), lineWidth: 1)
            )
    }
}

/// 小徽标
public struct FRBadge: View {
    private let text: String
    private let color: Color
    private let systemImage: String?
    public init(_ text: String, color: Color, icon: String? = nil) {
        self.text = text; self.color = color; self.systemImage = icon
    }
    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.system(size: 10, weight: .semibold))
        }
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.16)))
        .foregroundStyle(color)
        .accessibilityLabel(text)
    }
}

/// 健康状态圆点
public struct FRStatusDot: View {
    private let color: Color
    private let pulse: Bool
    public init(color: Color, pulse: Bool = false) { self.color = color; self.pulse = pulse }
    public var body: some View {
        ZStack {
            if pulse {
                Circle().fill(color.opacity(0.3)).frame(width: 14, height: 14)
                    .modifier(FRPulse())
            }
            Circle().fill(color).frame(width: 8, height: 8)
        }
    }
}

private struct FRPulse: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content.scaleEffect(on ? 1.5 : 0.8).opacity(on ? 0 : 0.8)
            .animation(.easeOut(duration: 1.4).repeatForever(autoreverses: false), value: on)
            .onAppear { on = true }
    }
}

/// 指标块（首页用）
public struct FRMetric: View {
    private let title: String
    private let value: String
    private let unit: String?
    private let icon: String
    private let tint: Color
    public init(_ title: String, value: String, unit: String? = nil, icon: String, tint: Color = FRDesign.accent) {
        self.title = title; self.value = value; self.unit = unit; self.icon = icon; self.tint = tint
    }
    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 20, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .accessibilityLabel("\(title) \(value)")
                if let unit { Text(unit).font(.system(size: 10)).foregroundStyle(.secondary) }
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(0.9))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(tint.opacity(0.18), lineWidth: 1))
    }
}

/// 空状态插图（代码绘制，无需图片资源）
public struct FREmptyState: View {
    private let icon: String
    private let title: String
    private let detail: String
    private var action: (() -> Void)?
    private var actionTitle: String?

    public init(icon: String, title: String, detail: String, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.icon = icon; self.title = title; self.detail = detail
        self.actionTitle = actionTitle; self.action = action
    }
    public var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(FRDesign.accent.opacity(0.10)).frame(width: 78, height: 78)
                Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(FRDesign.accent)
            }
            Text(title).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            if let action, let actionTitle {
                Button(action: action) {
                    Text(actionTitle).font(.system(size: 13, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(FRDesign.accent.opacity(0.16)))
                }
                .buttonStyle(.plain).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 34)
        .accessibilityElement(children: .combine)
    }
}

/// 网关状态图标（AI 路由核心的代码绘制占位图形，与应用图标同主题）
public struct FRRoutingGlyph: View {
    private let size: CGFloat
    private let animated: Bool
    public init(size: CGFloat = 64, animated: Bool = true) { self.size = size; self.animated = animated }
    @State private var phase: Double = 0
    public var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                let angle = Double(i) * 60 + (animated ? phase : 0)
                Circle()
                    .fill(FRDesign.accentCyan.opacity(0.85))
                    .frame(width: size * 0.075)
                    .offset(x: cos(angle * .pi / 180) * size * 0.4, y: sin(angle * .pi / 180) * size * 0.4)
                Path { p in
                    let r = size * 0.4
                    p.move(to: CGPoint(x: size / 2, y: size / 2))
                    p.addLine(to: CGPoint(x: size / 2 + cos(angle * .pi / 180) * r,
                                          y: size / 2 + sin(angle * .pi / 180) * r))
                }
                .stroke(FRDesign.accent.opacity(0.35), lineWidth: 1)
            }
            Circle().fill(FRDesign.accent).frame(width: size * 0.24)
                .shadow(color: FRDesign.accent.opacity(0.8), radius: size * 0.12)
            Circle().fill(.white.opacity(0.9)).frame(width: size * 0.09)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard animated else { return }
            withAnimation(.linear(duration: 9).repeatForever(autoreverses: false)) { phase = 360 }
        }
        .accessibilityHidden(true)
    }
}

/// 数字格式化工具
public enum FRFormat {
    public static func compact(_ n: Int) -> String {
        switch n {
        case ..<1_000: return "\(n)"
        case ..<1_000_000: return String(format: "%.1fk", Double(n) / 1_000)
        default: return String(format: "%.2fM", Double(n) / 1_000_000)
        }
    }
    public static func ms(_ v: Double) -> String {
        v >= 1000 ? String(format: "%.2fs", v / 1000) : String(format: "%.0fms", v)
    }
    public static func percent(_ v: Double) -> String { String(format: "%.1f%%", v * 100) }
    public static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
    public static func dateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
    public static func context(_ n: Int?) -> String {
        guard let n else { return "—" }
        if n >= 1024 { return "\(n / 1024)K" }
        return "\(n)"
    }
}
