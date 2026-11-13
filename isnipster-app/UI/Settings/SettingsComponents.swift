// 阅读路线
// 设置分组、行容器、按钮样式和动态颜色等可复用展示组件，类似 Vue 基础组件库。
// 泛型 View 参数相当于有类型的 slot；业务配置由调用处传入，组件只负责布局。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import SwiftUI

/// 带分组标题的设置内容容器。
struct SettingsGroup<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// 为一组设置行提供统一卡片背景和圆角。
struct SettingsRows<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
        .background(SettingsPalette.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

/// 由标题、说明和尾部控件构成的标准设置行。
struct SettingsRow<Trailing: View>: View {
    let title: String
    let detail: String?
    let trailing: Trailing

    init(
        _ title: String,
        detail: String? = nil,
        // @ViewBuilder 是结果构建器：把闭包内的多个 View 和条件分支组合成一个静态类型的视图结果。
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
        .padding(.horizontal, 16)
        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
        .frame(minHeight: detail == nil ? 48 : 58)
        // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 16)
        }
    }
}

/// 设置页主要操作按钮的强调样式。
struct SettingsPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .background(
                Color.accentColor.opacity(configuration.isPressed ? 0.78 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

/// 设置页顶部导航按钮使用的紧凑样式。
struct SettingsToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(configuration.isPressed ? Color.primary : Color.secondary)
            .frame(width: 22, height: 30)
            .contentShape(Rectangle())
    }
}

/// 外观与输入字段一致的设置按钮样式。
struct SettingsFieldButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                SettingsPalette.fieldBackground.opacity(configuration.isPressed ? 0.72 : 1),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(SettingsPalette.fieldBorder, lineWidth: 1)
            }
    }
}

/// 集中定义设置窗口在浅色和深色模式下使用的颜色。
enum SettingsPalette {
    static let switchGreen = Color(red: 0.18, green: 0.78, blue: 0.35)
    static let sidebarBackground = dynamicColor(light: 0.935, dark: 0.13)
    static let toolbarBackground = dynamicColor(light: 0.955, dark: 0.12)
    static let contentBackground = dynamicColor(light: 0.965, dark: 0.10)
    static let searchBackground = dynamicColor(light: 0.875, dark: 0.20)
    static let cardBackground = dynamicColor(light: 0.995, dark: 0.17)
    static let fieldBackground = dynamicColor(light: 0.995, dark: 0.22)
    static let fieldBorder = dynamicColor(light: 0.78, dark: 0.34)

    private static func dynamicColor(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return NSColor(calibratedWhite: match == .darkAqua ? dark : light, alpha: 1)
        })
    }
}
