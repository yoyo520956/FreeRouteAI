import SwiftUI
import UIKit

/// 界面适配基础层。
///
/// 依据 Apple《Human Interface Guidelines → Layout》（2026-09-09 更新版）：
/// 「Determine layout based on size classes, not device type or orientation.」
/// 原因很实际：同一台 iPhone 在「显示缩放=放大」时渲染尺寸会变小，
/// 镜像到 Mac 上窗口还能任意拖宽拖高，而机型 idiom 永远不变 ——
/// 所以只有 size class 才真正反映「现在有多少空间可用」。
///
/// 约定：本文件之外不允许再出现 `UI_USER_INTERFACE_IDIOM()`、
/// 「是不是 iPhone」这类判断，也不允许用固定像素宽去决定布局列数。
enum FRLayout {

    /// 水平方向是否紧凑（iPhone 竖屏、iPad 窄分屏、Mac 窄窗都算紧凑）。
    /// `horizontalSizeClass` 在 iOS 上理论上可能为 nil（文档里是可选值），
    /// 因此缺省按最保守的 compact 处理，保证窄屏优先不出错。
    static func isCompact(_ horizontal: UserInterfaceSizeClass?) -> Bool {
        (horizontal ?? .compact) == .compact
    }

    /// 按 size class 决定网格列数。
    static func columnCount(_ horizontal: UserInterfaceSizeClass?,
                            compact: Int, regular: Int) -> Int {
        isCompact(horizontal) ? compact : regular
    }

    /// 等分网格：窄屏 compact 列、宽屏 regular 列。
    /// 用 `.flexible()` 而不是固定宽度，列宽由容器等分，
    /// 这样从 SE 的小屏到 iPad 拖窗都不会溢出（HIG 要求布局能顺势伸缩）。
    static func grid(_ horizontal: UserInterfaceSizeClass?,
                     compact: Int, regular: Int,
                     spacing: CGFloat = 8) -> [GridItem] {
        let count = columnCount(horizontal, compact: compact, regular: regular)
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: count)
    }
}

// MARK: - 通用自适应零件

/// 「标题 + 右侧控件」的头部行。
///
/// 窄屏或超大字号时，标题和控件放不进同一行，Apple 的
/// `ViewThatFits` 会自动退到上下排布（HIG：horizontally adjacent views
/// may need to stack vertically to provide more space for text），
/// 因此不需要按机型写 if/else。
struct FRAdaptiveHeader<Title: View, Control: View>: View {
    private let title: () -> Title
    private let control: () -> Control
    private let controlIdealWidth: CGFloat

    init(controlWidth: CGFloat = 150,
         @ViewBuilder title: @escaping () -> Title,
         @ViewBuilder control: @escaping () -> Control) {
        self.controlIdealWidth = controlWidth
        self.title = title
        self.control = control
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                title()
                Spacer(minLength: 8)
                control().frame(width: controlIdealWidth)
            }
            VStack(alignment: .leading, spacing: 8) {
                title()
                control()
            }
        }
    }
}

/// 标签 + 值的两态行（用于 ScrollView 里，不在 Form 内的场景）。
///
/// 放得下就左右对齐成一行，放不下（窄屏、Dynamic Type 特大字号、
/// 德语等长词语言）自动变成上下排，值永不裁切 —— 这正是 HIG
/// 「Be prepared for text-size changes」要求的行为。
/// 固定像素列宽（以前是 64/56pt）已废弃：它对大字号无效。
struct FRKeyValueRow: View {
    let key: String
    let value: String
    var keyFont: Font = .system(size: 11, weight: .medium)
    var valueFont: Font = .system(size: 12)

    init(_ key: String, _ value: String,
         keyFont: Font = .system(size: 11, weight: .medium),
         valueFont: Font = .system(size: 12)) {
        self.key = key
        self.value = value
        self.keyFont = keyFont
        self.valueFont = valueFont
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 8) {
                Text(key).font(keyFont).foregroundStyle(.secondary).fixedSize()
                Text(value).font(valueFont)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(key).font(keyFont).foregroundStyle(.secondary)
                Text(value).font(valueFont)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
