// 阅读路线
// 配置截图自动识别失败时的备用语言组合，并与 AppModel 持久化属性绑定。
// Picker 标签负责显示，tag 负责实际存值；语言代码传给系统，不要用本地化名称作为标识。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import ImageTranslationFeature
import MacPlatform
import iSnipsterCore
import SwiftUI

extension SettingsView {
    var translationSettings: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: AppText.text(.textTranslationTarget)) {
                SettingsRows {
                    SettingsRow(AppText.text(.targetLanguage)) {
                        Picker(AppText.text(.targetLanguage), selection: $model.translationTarget) {
                            Text(AppText.text(.simplifiedChinese)).tag("zh-Hans")
                            Text(AppText.text(.english)).tag("en-US")
                            Text(AppText.text(.japanese)).tag("ja-JP")
                            Text(AppText.text(.korean)).tag("ko-KR")
                        }
                        .labelsHidden()
                        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                        .frame(width: 180)
                    }
                }
            }

            SettingsGroup(title: AppText.text(.screenshotLanguages)) {
                SettingsRows {
                    SettingsRow(AppText.text(.sourceLanguage)) {
                        screenshotLanguagePicker(
                            selection: $model.screenshotTranslationSource,
                            counterpart: $model.screenshotTranslationTarget
                        )
                    }
                    SettingsRow(AppText.text(.targetLanguage)) {
                        screenshotLanguagePicker(
                            selection: $model.screenshotTranslationTarget,
                            counterpart: $model.screenshotTranslationSource
                        )
                    }
                    SettingsRow(
                        AppText.text("截图翻译超时"),
                        detail: AppText.text("包含文字识别、语言包准备和翻译，超时后可重试。")
                    ) {
                        Stepper(
                            AppText.format("%d 秒", screenshotTranslationTimeoutSeconds),
                            value: $screenshotTranslationTimeoutSeconds,
                            in: AppPreferences.Translation.screenshotTimeoutRange,
                            step: 5
                        )
                        .frame(width: 180)
                    }
                }
            }

            SettingsGroup(title: AppText.text("隐私")) {
                SettingsRows {
                    SettingsRow(
                        AppText.text("复制译文不会新增历史记录"),
                        detail: AppText.text("Apple 翻译在本机处理；启用在线翻译源时，原文会发送给对应服务。")
                    ) {
                        Image(systemName: "lock.shield")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func screenshotLanguagePicker(
        selection: Binding<String>,
        counterpart: Binding<String>
    ) -> some View {
        let languageBinding = Binding<String>(
            get: { selection.wrappedValue },
            set: { language in
                // 选中另一端的语言时互换，始终保留有效的翻译方向。
                let previous = selection.wrappedValue
                if counterpart.wrappedValue == language {
                    counterpart.wrappedValue = previous
                }
                selection.wrappedValue = language
            }
        )
        return Picker(AppText.text(.language), selection: languageBinding) {
            // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
            ForEach(ScreenshotTranslationFallback.supportedLanguageIdentifiers, id: \.self) { identifier in
                let title = switch identifier {
                case "zh-Hans": AppText.text(.simplifiedChinese)
                case "en-US": AppText.text(.english)
                case "ja-JP": AppText.text(.japanese)
                case "ko-KR": AppText.text(.korean)
                default: identifier
                }
                Text(title).tag(identifier)
            }
        }
        .labelsHidden()
        .frame(width: 180)
    }
}
