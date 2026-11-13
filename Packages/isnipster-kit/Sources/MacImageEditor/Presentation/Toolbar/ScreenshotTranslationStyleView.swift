import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 展示当前截图语言方向，并异步读取系统支持语言；用户选择保存到当前 session。
// 这些选项不修改全局偏好；开始翻译通过动作回调，语言列表加载本身不发起翻译。
// 官方参考（系统支持语言查询）：https://developer.apple.com/documentation/translation/languageavailability

import SwiftUI
import iSnipsterCore
@preconcurrency import Translation

/// 翻译副工具栏只编辑语言参数、发送开始命令；窗口布局和玻璃外壳由现有属性栏负责。
@MainActor
struct ScreenshotTranslationStyleView: View {
    // @Bindable 为 @Observable 对象生成 $属性 绑定，类似 v-model 通道；对象的创建和共享仍由外层负责。
    @Bindable var session: InlineEditorSession
    let onAction: (ScreenshotToolbarAction) -> Void
    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State private var languageIdentifiers: [String] = []

    private var canTranslate: Bool {
        languageIdentifiers.contains(session.translationTargetLanguage)
            && (session.translationSourceLanguage == "auto"
                || languageIdentifiers.contains(session.translationSourceLanguage))
            && session.translationSourceLanguage != session.translationTargetLanguage
    }

    private var canSwapLanguages: Bool {
        session.translationSourceLanguage != "auto" && canTranslate
    }

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        HStack(spacing: 6) {
            languageMenu(
                title: AppText.text(.sourceLanguage),
                selection: $session.translationSourceLanguage,
                allowsAutomatic: true
            )

            Button {
                guard !session.isProcessing, canSwapLanguages else { return }
                let source = session.translationSourceLanguage
                session.translationSourceLanguage = session.translationTargetLanguage
                session.translationTargetLanguage = source
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .resizable()
                    .scaledToFit()
                    // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                    .frame(width: 11, height: 11)
                    .frame(width: 28, height: 22)
            }
            .buttonStyle(.plain)
            .modifier(TranslationControlChrome())
            .focusable(false)
            // 为 VoiceOver 提供语义标签；只有图标时尤其需要，不能只靠鼠标悬停提示表达动作。
            .accessibilityLabel(AppText.text(.swapLanguages))
            .help(session.translationSourceLanguage == "auto"
                ? AppText.text(.chooseSourceToSwap)
                : AppText.text(.swapLanguages))

            languageMenu(
                title: AppText.text(.targetLanguage),
                selection: $session.translationTargetLanguage,
                allowsAutomatic: false
            )

            Button {
                guard !session.isProcessing, canTranslate else { return }
                onAction(.startTranslation)
            } label: {
                Text(AppText.text(.translate))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 48, height: 22)
            }
            .buttonStyle(.plain)
            .modifier(TranslationControlChrome(prominent: true))
            .focusable(false)
            .help(AppText.text(.chooseDifferentLanguages))
        }
        // 只控制是否参与交互命中，不改变绘制或布局；适合让进度提示、装饰边框透传鼠标。
        .allowsHitTesting(!session.isProcessing)
        .font(.system(size: 12))
        // SwiftUI 管理这个异步任务的生命周期；视图消失时请求取消，任务内部仍需要正确响应取消。
        .task { await loadLanguages() }
    }

    private func languageMenu(
        title: String,
        selection: Binding<String>,
        allowsAutomatic: Bool
    ) -> some View {
        Menu {
            if allowsAutomatic {
                languageOption("auto", selection: selection)
                Divider()
            }
            // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
            ForEach(languageIdentifiers, id: \.self) { identifier in
                languageOption(identifier, selection: selection)
            }
        } label: {
            HStack(spacing: 6) {
                Text(languageTitle(selection.wrappedValue))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
            }
            // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity)
            .frame(height: 22)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .modifier(TranslationControlChrome())
        .accessibilityLabel(title)
        .help(languageTitle(selection.wrappedValue))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func languageOption(_ identifier: String, selection: Binding<String>) -> some View {
        Button {
            guard !session.isProcessing else { return }
            selection.wrappedValue = identifier
        } label: {
            Text(languageTitle(identifier))
        }
    }

    private func languageTitle(_ identifier: String) -> String {
        if identifier == "auto" { return AppText.text(.autoDetect) }
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    /// 从系统读取实际支持的语言，不将其他在线翻译接口的语言列表误用于 Apple 翻译。
    private func loadLanguages() async {
        let languages = await LanguageAvailability().supportedLanguages
        guard !Task.isCancelled else { return }
        languageIdentifiers = Array(Set(languages.map(\.minimalIdentifier))).sorted {
            languageTitle($0).localizedStandardCompare(languageTitle($1)) == .orderedAscending
        }

        if languageIdentifiers.isEmpty {
            session.errorMessage = AppText.text(.translationNoLanguages)
        }

        // 应用设置使用 en-US 等地区标识，而系统列表可能返回 en；映射到同语言、同文字体系。
        // 不在列表中时保留原值，让用户明确选择，避免静默改成另一种目标语言。
        session.translationTargetLanguage = matchingIdentifier(for: session.translationTargetLanguage)
        if session.translationSourceLanguage != "auto" {
            session.translationSourceLanguage = matchingIdentifier(for: session.translationSourceLanguage)
        }
    }

    private func matchingIdentifier(for identifier: String) -> String {
        TranslationLanguage.matchingIdentifier(identifier, supported: languageIdentifiers)
    }
}
