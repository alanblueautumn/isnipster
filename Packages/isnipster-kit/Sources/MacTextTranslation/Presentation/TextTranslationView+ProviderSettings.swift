import MacShared
import MacPreferences
import MacTranslation
// 阅读路线
// 把 provider 集合映射为开关和排序控件；切换时调用 Model 方法维护配置。
// Binding(get:set:) 类似 Vue 带 setter 的 computed，把集合成员关系投影为 Bool。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import AVFoundation
import ClipboardFeature
import NaturalLanguage
import Observation
import TextTranslationFeature
import iSnipsterCore
import SwiftUI

/// 翻译源设置弹层。`Binding(get:set:)` 把 `Set` 是否包含某个 provider 投影成 Toggle 需要的 `Binding<Bool>`；
/// 类似 Vue 为 `v-model` 提供计算属性的 getter/setter，修改最终仍由 Model 方法集中处理。
extension TextTranslationView {
    var providerSettingsPanel: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(alignment: .leading, spacing: 10) {
            Text(AppText.text("翻译源"))
                .font(.headline)

            // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
            ForEach(Array(model.providerOrder.enumerated()), id: \.element) { index, provider in
                HStack(spacing: 8) {
                    Toggle(
                        // Binding(get:set:) 将现有状态投影为控件需要的值；类似 Vue computed 的读写代理。
                        isOn: Binding(
                            get: { model.enabledProviders.contains(provider) },
                            set: { model.setProvider(provider, enabled: $0) }
                        )
                    ) {
                        Label(provider.title, systemImage: provider.systemImage)
                    }
                    .toggleStyle(.switch)

                    Spacer(minLength: 8)

                    Button {
                        model.moveProvider(provider, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.plain)
                    // 通过环境向子控件传递禁用状态；这是交互限制，耗时任务入口仍需要自己的重复调用防护。
                    .disabled(index == 0)
                    .help(AppText.text("上移"))

                    Button {
                        model.moveProvider(provider, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.plain)
                    .disabled(index == model.providerOrder.count - 1)
                    .help(AppText.text("下移"))
                }
            }

            Text(AppText.text("启用有道、Google 或 DeepL 后，原文会发送到对应第三方服务；网页接口可能随服务方调整而失效。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
        .padding(14)
        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
        .frame(width: 330)
    }
}
