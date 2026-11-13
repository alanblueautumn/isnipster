// 阅读路线
// 统一翻译控件的背景与悬停效果，同时读取环境中的 isEnabled 显示禁用态。
// @Environment 像框架提供的上下文，@State 则由当前控件拥有，二者生命周期不同。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import SwiftUI

/// 翻译面板和截图翻译共用的控件背景、禁用态与悬停反馈。
public struct TranslationControlChrome: ViewModifier {
    private let prominent: Bool

    public init(prominent: Bool = false) { self.prominent = prominent }
    // @Environment 从视图树的环境读取框架值或动作，类似 Vue inject；这里不创建系统服务实例。
    @Environment(\.isEnabled) private var isEnabled
    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State private var isHovering = false

    public func body(content: Content) -> some View {
        content
            .foregroundStyle(prominent ? Color.white : Color.primary)
            // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
            .background(
                backgroundColor,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(isEnabled ? 1 : 0.48)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.10)) {
                    isHovering = hovering
                }
            }
    }

    private var backgroundColor: Color {
        if prominent {
            return Color.accentColor.opacity(isHovering ? 0.86 : 1)
        }
        return Color.primary.opacity(isHovering ? 0.12 : 0.075)
    }
}
