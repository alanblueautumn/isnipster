// 阅读路线
// 状态栏菜单是 SwiftUI 内容，外层 AppDelegate 的 NSPanel 负责位置与外部点击关闭。
// 按钮将用户意图交给 AppModel；设置入口使用系统 openSettings 动作打开 Settings Scene。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import MacPlatform
import SwiftUI

/// 状态栏的紧凑功能菜单。
struct MenuBarContentView: View {
    // @Bindable 为 @Observable 对象生成 $属性 绑定，类似 v-model 通道；对象的创建和共享仍由外层负责。
    @Bindable var model: AppModel
    var onDismiss: () -> Void = {}

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(alignment: .leading, spacing: 0) {
            actionButton(
                AppText.text("截图"),
                shortcut: model.shortcutText(for: .capture),
                icon: "viewfinder",
                action: model.capture
            )
            actionButton(
                AppText.text("剪切板"),
                shortcut: model.shortcutText(for: .clipboard),
                icon: "clipboard",
                action: model.showClipboard
            )
            actionButton(
                AppText.text(.translate),
                shortcut: model.shortcutText(for: .textTranslation),
                icon: "character.bubble",
                action: model.showTextTranslation
            )
            menuSeparator
            MenuSettingsButton(onDismiss: onDismiss)
            menuSeparator
            actionButton(AppText.text("退出"), icon: "power") {
                NSApp.terminate(nil)
            }
        }
        .font(.system(size: 14))
        // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
        .padding(7)
        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
        .frame(width: 220, height: 154)
        .modifier(MenuBarGlassSurface())
        // 顶部不留空隙，菜单直接贴住状态栏；其余方向为轻量投影保留空间。
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func actionButton(
        _ title: String,
        shortcut: String = "",
        icon: String,
        action: @escaping () -> Void
    ) -> some View {
        MenuActionButton(
            title: title,
            shortcut: shortcut,
            icon: icon
        ) {
            onDismiss()
            action()
        }
    }

    private var menuSeparator: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.16))
            .frame(height: 1)
            .padding(.vertical, 2)
    }
}

/// 使用系统 Liquid Glass 绘制菜单表面，并为旧版 macOS 提供原生材质降级。
private struct MenuBarGlassSurface: ViewModifier {
    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    private let surfaceTint = Color(nsColor: .windowBackgroundColor).opacity(0.32)

    // @ViewBuilder 是结果构建器：把闭包内的多个 View 和条件分支组合成一个静态类型的视图结果。
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content
                // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
                .background(surfaceTint, in: shape)
                .glassEffect(.regular, in: shape)
                // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
                .overlay {
                    shape
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.6)
                        // 只控制是否参与交互命中，不改变绘制或布局；适合让进度提示、装饰边框透传鼠标。
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
        } else {
            content
                .background(.thinMaterial, in: shape)
                .background(surfaceTint, in: shape)
                .overlay {
                    shape
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.7)
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.20), radius: 4, x: 0, y: 2)
        }
    }
}

/// 在状态栏菜单中打开应用设置并关闭当前菜单面板。
private struct MenuSettingsButton: View {
    // @Environment 从视图树的环境读取框架值或动作，类似 Vue inject；这里不创建系统服务实例。
    @Environment(\.openSettings) private var openSettings
    let onDismiss: () -> Void
    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State private var isHovered = false

    var body: some View {
        Button {
            onDismiss()
            openSettings()
            SettingsWindowPresentation.bringToFront()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "gearshape").frame(width: 18)
                Text(AppText.text("设置"))
                Spacer()
            }
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                isHovered ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// 状态栏菜单统一使用的图标、标题、快捷键和悬停样式按钮。
private struct MenuActionButton: View {
    let title: String
    let shortcut: String
    let icon: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 18)
                Text(title)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(isHovered ? Color.white.opacity(0.9) : Color.secondary)
            }
            .foregroundStyle(isHovered ? Color.white : Color.primary)
            .padding(.horizontal, 7)
            .frame(height: 26)
            .background(
                isHovered ? Color.accentColor : Color.clear,
                in: RoundedRectangle(cornerRadius: 5, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
