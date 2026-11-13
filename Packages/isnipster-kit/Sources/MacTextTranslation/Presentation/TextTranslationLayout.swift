import MacShared
import MacPreferences
import MacTranslation
// 阅读路线
// PreferenceKey 把子视图测得的高度向上传，Layout 为词形标签做测量和换行定位。
// 与 CSS 自动布局不同，自定义 Layout 分开实现“需要多大”和“放在哪里”，两次计算应保持一致。
// 官方参考（SwiftUI 自定义布局）：https://developer.apple.com/documentation/swiftui/layout

import SwiftUI

/// 把原文编辑区的实际高度向上传递给窗口尺寸计算。
struct TranslationSourceEditorHeightPreferenceKey: SwiftUI.PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 把翻译状态消息的实际高度向上传递给窗口尺寸计算。
struct TranslationMessageHeightPreferenceKey: SwiftUI.PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 把翻译结果区的实际高度向上传递给窗口尺寸计算。
struct TranslationResultsHeightPreferenceKey: SwiftUI.PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 读取原文编辑区尺寸并写入对应 PreferenceKey。
struct TranslationSourceEditorHeightReader: View {
    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // GeometryReader 提供父布局给出的可用尺寸，单位为 point；布局尺寸不等于截图的像素尺寸。
        GeometryReader { geometry in
            Color.clear.preference(
                key: TranslationSourceEditorHeightPreferenceKey.self,
                value: geometry.size.height
            )
        }
    }
}

/// 读取状态消息尺寸并写入对应 PreferenceKey。
struct TranslationMessageHeightReader: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: TranslationMessageHeightPreferenceKey.self,
                value: geometry.size.height
            )
        }
    }
}

/// 读取翻译结果尺寸并写入对应 PreferenceKey。
struct TranslationResultsHeightReader: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: TranslationResultsHeightPreferenceKey.self,
                value: geometry.size.height
            )
        }
    }
}

/// 将词形标签从左到右紧凑排列，并在剩余宽度不足时自动换行。
struct TranslationTagFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    /// 先计算流式标签布局，再把内容所需尺寸报告给 SwiftUI；此阶段不真正移动子视图。
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        layout(subviews: subviews, width: proposal.width ?? .infinity).size
    }

    /// 按与测量相同的规则定位每个标签，避免测量结果与最终换行位置不一致。
    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let result = layout(subviews: subviews, width: bounds.width)
        for placement in result.placements {
            placement.subview.place(
                at: CGPoint(
                    x: bounds.minX + placement.origin.x,
                    y: bounds.minY + placement.origin.y
                ),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func layout(
        subviews: Subviews,
        width: CGFloat
    ) -> (size: CGSize, placements: [Placement]) {
        var placements: [Placement] = []
        var origin = CGPoint.zero
        var lineHeight: CGFloat = 0
        var contentWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > width {
                origin.x = 0
                origin.y += lineHeight + verticalSpacing
                lineHeight = 0
            }
            placements.append(Placement(subview: subview, origin: origin, size: size))
            contentWidth = max(contentWidth, origin.x + size.width)
            lineHeight = max(lineHeight, size.height)
            origin.x += size.width + horizontalSpacing
        }

        return (
            CGSize(width: min(contentWidth, width), height: origin.y + lineHeight),
            placements
        )
    }

    /// 保存一个词形标签在流式布局中的最终位置和尺寸。
    private struct Placement {
        let subview: LayoutSubview
        let origin: CGPoint
        let size: CGSize
    }
}

/// 为翻译窗口图标按钮提供统一的悬停背景与阴影。
struct TranslationButtonHoverBackground: ViewModifier {
    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
            .background(
                isHovering ? Color.primary.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .shadow(
                color: isHovering ? Color.black.opacity(0.18) : Color.clear,
                radius: isHovering ? 3 : 0,
                y: isHovering ? 1 : 0
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.10)) {
                    isHovering = hovering
                }
            }
    }
}
