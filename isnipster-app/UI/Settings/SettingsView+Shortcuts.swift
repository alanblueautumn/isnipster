// 阅读路线
// 展示应用级和截图会话级快捷键；录制控件统一，保存和冲突处理按动作作用域分开。
// 显示文案、默认值、持久化与键盘分发要对应同一动作，不能只改设置行的标题。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import MacPlatform
import iSnipsterCore
import SwiftUI

/// 快捷键设置页同时覆盖全局热键和截图会话内热键。前者由系统事件服务注册，后者仅在截图窗口活跃时分发；
/// 两者的作用域不同，不能因为界面都叫“快捷键”就共用冲突规则。
extension SettingsView {
    var shortcutSettings: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: AppText.text("全局快捷键")) {
                SettingsRows {
                    // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
                    ForEach(AppShortcutAction.allCases) { action in
                        SettingsRow(action.title) {
                            HotKeyRecorder(
                                descriptor: model.shortcutDescriptor(for: action),
                                onRecord: { descriptor in
                                    model.setShortcut(descriptor, for: action)
                                }
                            )
                            // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                            .frame(width: 138, height: 30)
                        }
                    }
                }
            }

            SettingsGroup(title: AppText.text("截图工具快捷键")) {
                SettingsRows {
                    ForEach(ScreenshotToolShortcutAction.allCases) { action in
                        SettingsRow(action.title) {
                            if action.isCustomizable {
                                HotKeyRecorder(
                                    descriptor: screenshotToolShortcutDescriptor(for: action),
                                    onRecord: { descriptor in
                                        setScreenshotToolShortcut(descriptor, for: action)
                                    }
                                )
                                .frame(width: 138, height: 30)
                            } else {
                                Text(HotKeyDisplay.string(for: action.defaultDescriptor))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 138, height: 30)
                            }
                        }
                    }
                }
            }

            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                Text(
                    screenshotToolShortcutMessage
                        ?? model.shortcutConfigurationMessage
                        ?? AppText.text("点击快捷键后，按下新的按键或组合键即可立即生效；按 Esc 取消录制。")
                )
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
            .padding(.horizontal, 4)
        }
    }

    private func screenshotToolShortcutDescriptor(
        for action: ScreenshotToolShortcutAction
    ) -> HotKeyDescriptor {
        screenshotToolShortcuts[action] ?? action.defaultDescriptor
    }

    private func setScreenshotToolShortcut(
        _ descriptor: HotKeyDescriptor,
        for action: ScreenshotToolShortcutAction
    ) -> Bool {
        // 自定义映射在写入持久层前检测重复，保证同一截图会话内每个按键只表达一个动作。
        guard action.isCustomizable else { return false }
        if let conflict = screenshotToolShortcuts.first(where: {
            $0.key != action && $0.value == descriptor
        })?.key {
            screenshotToolShortcutMessage = AppText.format("与截图工具“%@”的快捷键冲突", conflict.title)
            return false
        }

        screenshotToolShortcuts[action] = descriptor
        ScreenshotToolShortcutStore.save(screenshotToolShortcuts)
        screenshotToolShortcutMessage = AppText.format(
            "“%@”已设为 %@",
            action.title,
            HotKeyDisplay.string(for: descriptor)
        )
        return true
    }
}
