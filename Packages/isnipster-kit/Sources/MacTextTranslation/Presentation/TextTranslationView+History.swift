import MacShared
import MacPreferences
import MacTranslation
// 阅读路线
// 展示当前进程中的历史快照，点击后让 Model 恢复输入和结果；此处不发起持久化。
// 空状态和条目列表都是状态的投影，历史的去重与数量限制在 Model 中统一处理。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import AVFoundation
import ClipboardFeature
import NaturalLanguage
import Observation
import TextTranslationFeature
import iSnipsterCore
import SwiftUI

/// 仅展示本次进程内的翻译历史。点击条目把快照恢复给 Model；View 不自行复制请求或维护第二份业务状态。
/// LazyVStack 按布局需要延迟创建子视图，适合滚动列表；它不承诺固定数量的行复用池。
extension TextTranslationView {
    var historyPanel: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(AppText.text("最近 10 条翻译"), systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                Spacer()
                if !model.history.isEmpty {
                    Button(AppText.text("清空"), action: model.clearHistory)
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if model.history.isEmpty {
                ContentUnavailableView(
                    AppText.text("暂无记录"),
                    systemImage: "text.badge.plus",
                    description: Text(AppText.text("本次运行会保留最近 10 条"))
                )
                // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
                        ForEach(model.history) { entry in
                            historyRow(entry)
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
        .padding(14)
        .frame(width: 340, height: 460)
    }

    private func historyRow(_ entry: TextTranslationHistoryEntry) -> some View {
        let preview = model.availableProviders
            .compactMap { entry.results[$0] }
            .first?.primaryText ?? ""

        return Button {
            model.restore(entry)
            isShowingHistory = false
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(languageTitle(entry.targetLanguage))
                    Spacer()
                    Text(AppText.format("%d 个结果", entry.results.count))
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)

                Text(entry.sourceText)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)

                Text(preview)
                    .font(.caption)
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(9)
            // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}
