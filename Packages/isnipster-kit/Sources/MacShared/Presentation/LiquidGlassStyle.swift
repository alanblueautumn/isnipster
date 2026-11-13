// 阅读路线
// 将系统版本判断封装在 View 扩展里：可用时使用原生玻璃，否则使用材质样式。
// @ViewBuilder 允许分支产生不同具体 View 类型；some View 隐藏类型细节但仍由编译器静态确定。
// 官方参考（SwiftUI 玻璃效果）：https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views

import SwiftUI

/// 为 SwiftUI 视图提供统一的 Liquid Glass 样式和旧系统材质降级，调用方式类似组合 CSS 工具类。
public extension View {
    // @ViewBuilder 是结果构建器：把闭包内的多个 View 和条件分支组合成一个静态类型的视图结果。
    @ViewBuilder
    func isnipsterGlass<S: Shape>(
        _ shape: S,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        // 运行时检查系统版本，也让编译器允许在此分支调用 macOS 26 才引入的 API。
        if #available(macOS 26.0, *) {
            glassEffect(
                Glass.regular.tint(tint).interactive(interactive),
                in: shape
            )
        } else {
            background(.ultraThinMaterial, in: shape)
                // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
                .overlay {
                    shape.stroke(Color.white.opacity(0.20), lineWidth: 0.7)
                }
        }
    }

    @ViewBuilder
    func isnipsterGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26.0, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else if prominent {
            buttonStyle(.borderedProminent)
        } else {
            buttonStyle(.bordered)
        }
    }

    /// 邻近的玻璃控件统一批处理，减少重复材质渲染并保留系统的融合过渡。
    @ViewBuilder
    func isnipsterGlassContainer(spacing: CGFloat = 8) -> some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                self
            }
        } else {
            self
        }
    }
}
