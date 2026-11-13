// 阅读路线
// 展示本地数据处理方式并提供清理入口；动作委托给 AppModel/Controller。
// View 中的提示与错误状态来自实际操作结果，不应把按钮点击本身当成已经清理成功。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import MacPlatform
import iSnipsterCore
import SwiftUI

/// 隐私设置页展示数据流和可执行的清理入口；文字承诺必须与实际平台适配器的存储和网络行为保持一致。
/// 与 Web 的隐私页类似，但 macOS 的沙盒目录、TCC 授权和系统剪贴板属于额外的平台边界。
extension SettingsView {
    var privacySettings: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(alignment: .leading, spacing: 14) {
            SettingsGroup(title: AppText.text("数据处理")) {
                SettingsRows {
                    SettingsRow(
                        AppText.text("截图与 OCR"),
                        detail: AppText.text("仅在你主动操作时处理；截图、识别与图片翻译在本机完成。")
                    ) {
                        Image(systemName: "desktopcomputer")
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow(
                        AppText.text("文本翻译"),
                        detail: AppText.text("Apple Translation 在本机处理；你启用的有道、Google 或 DeepL 会收到待翻译原文。翻译历史仅保留到本次退出。")
                    ) {
                        Image(systemName: "apple.logo")
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow(
                        AppText.text("跟踪与分析"),
                        detail: AppText.text("应用不包含广告、分析 SDK 或跨应用跟踪。")
                    ) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsGroup(title: AppText.text("本地存储与删除")) {
                SettingsRows {
                    SettingsRow(
                        AppText.text("剪贴板历史"),
                        detail: AppText.text("按剪贴板设置保存在本机应用支持目录，可随时关闭记录或立即清空。")
                    ) {
                        Image(systemName: "internaldrive")
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow(
                        AppText.text("应用偏好"),
                        detail: AppText.text("快捷键、语言和界面选项通过 UserDefaults 保存在本机。")
                    ) {
                        Image(systemName: "gearshape")
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow(AppText.text("删除剪贴板历史"), detail: AppText.text("不会影响系统当前剪贴板。")) {
                        Button(AppText.text("立即清空"), role: .destructive, action: model.clearClipboardHistory)
                    }
                }
            }

            Text(AppText.text("卸载应用后，如需一并移除残留数据，可删除 iSnipster 的 macOS 沙盒容器。"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
                .padding(.horizontal, 4)
        }
    }
}
