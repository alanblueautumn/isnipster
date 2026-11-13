// 阅读路线
// 各个开关修改父视图持有的偏好值；父层统一检测策略快照变化并通知 Controller。
// 关闭采集与清空既有记录是不同动作，界面绑定要保持与 ClipboardHistoryPolicy 的含义一致。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import MacPlatform
import iSnipsterCore
import SwiftUI

/// 剪贴板策略设置页。Binding 直接写入 `SettingsView` 持有的偏好状态，外层统一监听后刷新采集器；
/// 相当于 Vue 中由父组件持有 store、子表单只修改受控状态，避免每个 Toggle 各自重启服务。
extension SettingsView {
    var clipboardSettings: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: AppText.text(.history)) {
                SettingsRows {
                    toggleRow(AppText.text(.recordHistory), binding: $recordsClipboardHistory)
                    SettingsRow(AppText.text(.historyLimit)) {
                        Picker(AppText.text(.historyLimit), selection: $clipboardHistoryLimit) {
                            Text(AppText.format(.itemCount, 100)).tag(100)
                            Text(AppText.format(.itemCount, 200)).tag(200)
                            Text(AppText.format(.itemCount, 500)).tag(500)
                            Text(AppText.format(.itemCount, 1000)).tag(1000)
                        }
                        .labelsHidden()
                        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                        .frame(width: 150)
                    }
                    SettingsRow(AppText.text(.retention)) {
                        Picker(AppText.text(.retention), selection: $clipboardRetentionDays) {
                            Text(AppText.format(.dayCount, 7)).tag(7)
                            Text(AppText.format(.dayCount, 30)).tag(30)
                            Text(AppText.format(.dayCount, 90)).tag(90)
                            Text(AppText.text(.forever)).tag(0)
                        }
                        .labelsHidden()
                        .frame(width: 150)
                    }
                    toggleRow(AppText.text(.clearExpired), binding: $clearsExpiredClipboardItems)
                }
            }

            SettingsGroup(title: AppText.text("内容类型")) {
                SettingsRows {
                    toggleRow(AppText.text(.recordText), binding: $recordsClipboardText)
                    toggleRow(AppText.text(.recordImages), binding: $recordsClipboardImages)
                    toggleRow(AppText.text(.recordFiles), binding: $recordsClipboardFiles)
                    toggleRow(AppText.text(.recordColors), binding: $recordsClipboardColors)
                }
            }

            SettingsGroup(title: AppText.text("安全与快捷")) {
                SettingsRows {
                    SettingsRow(
                        AppText.text("密码管理器内容始终忽略"),
                        detail: AppText.text("同时忽略系统剪贴板标记为临时、隐藏或自动生成的内容。")
                    ) {
                        Image(systemName: "lock.shield")
                            .foregroundStyle(.secondary)
                    }
                    toggleRow(AppText.text(.removeDuplicates), binding: $removesDuplicates)
                    SettingsRow(AppText.text("粘贴到当前光标")) {
                        Button(AppText.text(.openSystemSettings)) {
                            AppPermission.directPaste.openSystemSettings()
                        }
                    }
                    SettingsRow(
                        AppText.text("不在询问"),
                        detail: AppText.text("未授权时仅复制内容，手动按 Command-V 粘贴。关闭此选项可恢复授权提示。")
                    ) {
                        Toggle(AppText.text("不在询问"), isOn: $suppressesDirectPastePermissionPrompt)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                    SettingsRow(AppText.text("清空全部剪贴板历史"), detail: AppText.text("此操作不会影响系统当前剪贴板。")) {
                        Button(AppText.text("立即清空"), role: .destructive, action: model.clearClipboardHistory)
                    }
                }
            }
        }
    }
}
