// 阅读路线
// 固定背景色的工具栏外壳，根据 colorScheme 切换浅/深色；不使用会随 key window 改明暗的材质。
// ViewModifier 集中圆角、边框与背景顺序，调用方只传内容和圆角半径。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import SwiftUI

/// 截图浮层使用固定底色，避免工具栏与画布切换焦点时系统材质改变明暗。
private struct ScreenshotToolbarChrome: ViewModifier {
    // @Environment 从视图树的环境读取框架值或动作，类似 Vue inject；这里不创建系统服务实例。
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
            .background(
                Color(white: colorScheme == .dark ? 0.16 : 0.96),
                in: shape
            )
            // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
            .overlay {
                shape.stroke(
                    (colorScheme == .dark ? Color.white : Color.black).opacity(0.14),
                    lineWidth: 0.7
                )
            }
    }
}

public extension View {
    func screenshotToolbarChrome(cornerRadius: CGFloat = 8) -> some View {
        modifier(ScreenshotToolbarChrome(cornerRadius: cornerRadius))
    }
}
