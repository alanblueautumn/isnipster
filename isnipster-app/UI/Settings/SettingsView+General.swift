// 阅读路线
// 通用页展示登录启动与界面语言；页面负责绑定，系统注册操作在 SettingsView 中执行。
// 界面语言不是文本翻译的目标语言，二者有不同的持久化键与生效时机。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import MacPlatform
import ServiceManagement
import iSnipsterCore
import SwiftUI

/// “通用”设置页。SwiftUI View 是状态到界面的声明式映射：这里描述控件应如何随绑定值呈现，
/// 类似 Vue 模板，由状态驱动控件；登录项注册等副作用交给 SettingsView 的方法处理。
extension SettingsView {
    var generalSettings: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: AppText.text("界面")) {
                SettingsRows {
                    SettingsRow(
                        AppText.text(.applicationLanguage),
                        detail: AppText.text(.restartForLanguage)
                    ) {
                        Picker(AppText.text(.applicationLanguage), selection: appLanguageBinding) {
                            // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
                            ForEach(AppUILanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                        .frame(width: 300)
                    }
                }
            }

            SettingsGroup(title: AppText.text("启动")) {
                SettingsRows {
                    SettingsRow(
                        AppText.text(.launchAtLogin),
                        detail: launchAtLoginErrorMessage ?? launchAtLoginStatusDescription
                    ) {
                        HStack(spacing: 12) {
                            if launchAtLoginStatus == .requiresApproval {
                                // ServiceManagement 只能注册登录项；最终允许与否仍由 macOS 设置控制。
                                Button(AppText.text(.openSystemSettings)) {
                                    SMAppService.openSystemSettingsLoginItems()
                                }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Color.accentColor)
                            }

                            Toggle(AppText.text(.launchAtLogin), isOn: launchAtLoginBinding)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .tint(SettingsPalette.switchGreen)
                        }
                    }
                }
            }
        }
    }
}
