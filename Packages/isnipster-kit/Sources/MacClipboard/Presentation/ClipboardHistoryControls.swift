import MacShared
import MacPreferences
// 阅读路线
// 通过 ViewModifier 给操作按钮统一悬停外观；修改样式不触碰历史数据。
// modifier 接收原 content 并返回包裹后的 View，类似可复用的 Vue 展示容器。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import SwiftUI

/// 为剪贴板圆形操作按钮提供轻量悬停反馈。
@MainActor
struct ClipboardActionHoverBackground: ViewModifier {
    var isDestructive = false

    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(isDestructive && isHovered ? Color.red : Color.secondary)
            // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
            .background(
                isHovered
                    ? (isDestructive ? Color.red.opacity(0.14) : Color.primary.opacity(0.20))
                    : Color.clear,
                in: Circle()
            )
            .contentShape(Circle())
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
