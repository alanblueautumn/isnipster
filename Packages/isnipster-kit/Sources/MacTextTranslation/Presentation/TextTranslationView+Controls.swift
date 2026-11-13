import MacShared
import MacPreferences
import MacTranslation
// 阅读路线
// 标题栏、语言选择器和底栏通过 Binding 修改模型，通过回调请求窗口动作。
// Picker 的 tag 必须与绑定值类型一致；标签是显示文本，identifier 才是传给翻译服务的值。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import AVFoundation
import ClipboardFeature
import NaturalLanguage
import Observation
import TextTranslationFeature
import iSnipsterCore
import SwiftUI

extension TextTranslationView {
    /// 标题栏只管理置顶、历史和配置按钮；窗口动作通过回调交给 Presenter。
    var header: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        HStack(spacing: 10) {
            Button {
                isPinned.toggle()
                onPinChange(isPinned)
            } label: {
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isPinned ? Color.primary : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
            .frame(width: 24, height: 22)
            .modifier(TranslationButtonHoverBackground())
            .focusable(false)
            .help(isPinned ? AppText.text("取消窗口置顶") : AppText.text("将窗口置顶"))

            Spacer()

            Button {
                isShowingProviderSettings.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 22)
            .modifier(TranslationButtonHoverBackground())
            .focusable(false)
            .help(AppText.text("配置翻译源"))
            .popover(isPresented: $isShowingProviderSettings, arrowEdge: .bottom) {
                providerSettingsPanel
            }

            Button {
                isShowingHistory.toggle()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 22)
            .modifier(TranslationButtonHoverBackground())
            .focusable(false)
            .help(AppText.text("本次运行最近 10 条翻译"))
            .popover(isPresented: $isShowingHistory, arrowEdge: .bottom) {
                historyPanel
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .medium))
            }
            .buttonStyle(.plain)
            .frame(width: 24, height: 22)
            .modifier(TranslationButtonHoverBackground())
            .focusable(false)
            .help(AppText.text("关闭"))
        }
        // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
        .padding(.horizontal, 6)
        .frame(height: 22)
        // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
        .background {
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    WindowDragGesture()
                        .onEnded { _ in onWindowDragEnd() }
                )
        }
    }

    var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                footerIconButton(
                    "speaker.wave.2",
                    help: AppText.text("朗读原文"),
                    action: { model.speakSource() }
                )
                Spacer(minLength: 0)
                if !model.sourceText.isEmpty {
                    footerIconButton(
                        "xmark",
                        symbolSize: 10,
                        foregroundColor: Color.secondary.opacity(0.65),
                        help: AppText.text("清空原文"),
                        action: model.clearSourceContent
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ViewThatFits(in: .horizontal) {
                footerControls(languagePickerWidth: 96)
                footerControls(languagePickerWidth: 80)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .isnipsterGlassContainer(spacing: 10)
    }

    private func footerIconButton(
        _ systemName: String,
        symbolSize: CGFloat = 15,
        foregroundColor: Color = .primary,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .resizable()
                .scaledToFit()
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(foregroundColor)
                .frame(width: symbolSize, height: symbolSize)
                .frame(width: 26, height: 26)
        }
        .buttonStyle(.plain)
        .modifier(TranslationButtonHoverBackground())
        .focusable(false)
        .help(help)
    }

    private func footerControls(languagePickerWidth: CGFloat) -> some View {
        HStack(spacing: 6) {
            sourceLanguagePicker(width: languagePickerWidth)
            Button(action: model.swapTranslationLanguages) {
                Image(systemName: "arrow.left.arrow.right")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 11, height: 11)
                    .frame(width: 28, height: 22)
            }
            .buttonStyle(.plain)
            .modifier(TranslationControlChrome())
            .focusable(false)
            // 通过环境向子控件传递禁用状态；这是交互限制，耗时任务入口仍需要自己的重复调用防护。
            .disabled(!model.canSwapTranslationLanguages)
            .help(model.canSwapTranslationLanguages
                ? AppText.text(.swapLanguages)
                : AppText.text("请先选择不同的源语言和目标语言"))
            targetLanguagePicker(width: languagePickerWidth)
            Spacer(minLength: 6)
            translateButton
        }
    }

    private func sourceLanguagePicker(width: CGFloat) -> some View {
        Menu {
            languageOption(AppText.text(.autoDetect), identifier: "auto", source: true)
            languageOption(AppText.text("中文"), identifier: "zh-Hans", source: true)
            languageOption(AppText.text(.english), identifier: "en-US", source: true)
            languageOption(AppText.text(.japanese), identifier: "ja-JP", source: true)
            languageOption(AppText.text(.korean), identifier: "ko-KR", source: true)
        } label: {
            HStack(spacing: 6) {
                Text(sourceLanguageMenuTitle)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .frame(width: width, height: 22)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .modifier(TranslationControlChrome())
    }

    private func targetLanguagePicker(width: CGFloat) -> some View {
        Menu {
            languageOption(AppText.text("中文"), identifier: "zh-Hans", source: false)
            languageOption(AppText.text(.english), identifier: "en-US", source: false)
            languageOption(AppText.text(.japanese), identifier: "ja-JP", source: false)
            languageOption(AppText.text(.korean), identifier: "ko-KR", source: false)
        } label: {
            HStack(spacing: 6) {
                Text(languageTitle(model.targetLanguage))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .frame(width: width, height: 22)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .modifier(TranslationControlChrome())
    }

    private var sourceLanguageMenuTitle: String {
        guard model.sourceLanguage == "auto" else {
            return languageTitle(model.sourceLanguage)
        }
        return model.detectedSourceLanguageIdentifier.map {
            AppText.format("自动 · %@", languageTitle($0))
        } ?? AppText.text(.autoDetect)
    }

    private func languageOption(
        _ title: String,
        identifier: String,
        source: Bool
    ) -> some View {
        let isSelected = source
            ? model.sourceLanguage == identifier
            : model.targetLanguage == identifier
        return Button {
            if source {
                model.sourceLanguage = identifier
            } else {
                model.targetLanguage = identifier
            }
        } label: {
            HStack {
                Text(title)
                if isSelected {
                    Image(systemName: "checkmark")
                }
            }
        }
    }

    private var translateButton: some View {
        Button {
            model.translate()
        } label: {
            if model.isTranslating {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 48, height: 22)
            } else {
                Text(AppText.text(.translate))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 48, height: 22)
            }
        }
        .keyboardShortcut(.return, modifiers: [])
        .buttonStyle(.plain)
        .modifier(TranslationControlChrome(prominent: true))
        .disabled(
            model.isTranslating
                || model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }
    func languageTitle(_ identifier: String) -> String {
        switch identifier {
        case "zh-Hans": AppText.text("中文")
        case "zh-Hant": AppText.text("繁体中文")
        case "en-US": AppText.text(.english)
        case "ja-JP": AppText.text(.japanese)
        case "ko-KR": AppText.text(.korean)
        default: identifier
        }
    }
}
