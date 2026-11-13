import MacShared
import MacPreferences
// 阅读路线
// 输入和语言组成请求快照，每个翻译源维护任务/状态，结果到达时验证请求代号。
// 类似 Pinia 异步 action：取消旧请求之外还需拒绝旧回包；朗读与进程内历史也由此协调。
// 官方参考（系统语音合成）：https://developer.apple.com/documentation/avfaudio/avspeechsynthesizer

import AppKit
import ClipboardFeature
import Observation
import TextTranslationFeature
import iSnipsterCore
import SwiftUI

/// 驱动文本翻译窗口的可观察状态，协调输入、翻译任务、结果和历史记录。
@MainActor
@Observable
final class TextTranslationModel {
    var sourceText: String {
        didSet {
            guard sourceText != oldValue else { return }
            coordinator.cancel()
            updateAutomaticTargetLanguage()
        }
    }
    var sourceLanguage: String {
        didSet {
            guard sourceLanguage != oldValue else { return }
            coordinator.cancel()
            preferencesStore.setTextSourceLanguage(sourceLanguage)
            updateAutomaticTargetLanguage()
        }
    }
    var targetLanguage: String {
        didSet {
            guard targetLanguage != oldValue else { return }
            coordinator.cancel()
            onTargetLanguageChange(targetLanguage)
        }
    }
    var results: [TextTranslationProvider: TextTranslationResultState] { coordinator.results }
    private(set) var history: [TextTranslationHistoryEntry]
    private(set) var message: String?
    private(set) var failed = false
    private(set) var translationSequence = 0
    private(set) var providerOrder: [TextTranslationProvider]
    private(set) var enabledProviders: Set<TextTranslationProvider>

    private let preferencesStore: any TranslationPreferencesStoring
    private let coordinator: TextTranslationCoordinator
    private let clipboardWriter: any ClipboardWriting
    private let speech = TextSpeechService()
    private let onTargetLanguageChange: @MainActor (String) -> Void
    private var lastRequestContext: TranslationRequestContext?

    var availableProviders: [TextTranslationProvider] {
        providerOrder.filter(enabledProviders.contains)
    }

    var displayedProviders: [TextTranslationProvider] {
        availableProviders
    }

    var isTranslating: Bool {
        coordinator.isTranslating
    }

    var detectedSourceLanguageIdentifier: String? {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return TextLanguageDetector.detect(text)
    }

    var canSwapTranslationLanguages: Bool {
        guard !isTranslating, let source = sourceLanguageForSwap else { return false }
        return source != targetLanguage
    }

    private var sourceLanguageForSwap: String? {
        let source: String? = sourceLanguage == "auto" ? detectedSourceLanguageIdentifier : sourceLanguage
        guard let source, TranslationLanguage.settingsIdentifiers.contains(source) else { return nil }
        return source
    }

    init(
        sourceText: String,
        targetLanguage: String,
        service: any TextTranslationServicing,
        clipboardWriter: any ClipboardWriting,
        preferencesStore: any TranslationPreferencesStoring,
        onTargetLanguageChange: @escaping @MainActor (String) -> Void
    ) {
        self.sourceText = sourceText
        self.preferencesStore = preferencesStore
        let preferences = preferencesStore.load()
        sourceLanguage = preferences.textSourceLanguage
        self.targetLanguage = targetLanguage
        history = []
        providerOrder = preferences.providerOrder
        enabledProviders = preferences.enabledProviders
        coordinator = TextTranslationCoordinator(service: service)
        self.clipboardWriter = clipboardWriter
        self.onTargetLanguageChange = onTargetLanguageChange
        coordinator.onCompletion = { [weak self] request, results in
            guard let self else { return }
            let successes = results.compactMapValues(\.output)
            failed = successes.isEmpty && results.values.contains { $0.errorMessage != nil }
            message = nil
            if !successes.isEmpty {
                insertHistory(sourceText: request.text, results: successes, targetLanguage: request.targetLanguage)
            }
        }
        updateAutomaticTargetLanguage()
    }

    /// 更新启用集合，关闭某个来源时取消它的任务并移除结果，然后保存来源配置。
    func setProvider(_ provider: TextTranslationProvider, enabled: Bool) {
        if enabled {
            enabledProviders.insert(provider)
        } else {
            enabledProviders.remove(provider)
            coordinator.removeProvider(provider)
        }
        persistProviderConfiguration()
    }

    /// 将服务在显示顺序中前后移动并限制索引范围；排序与启用状态分开维护。
    func moveProvider(_ provider: TextTranslationProvider, offset: Int) {
        guard let sourceIndex = providerOrder.firstIndex(of: provider) else { return }
        let destinationIndex = min(max(sourceIndex + offset, 0), providerOrder.count - 1)
        guard sourceIndex != destinationIndex else { return }
        providerOrder.remove(at: sourceIndex)
        providerOrder.insert(provider, at: destinationIndex)
        persistProviderConfiguration()
    }

    /// 类似 Pinia 的搜索 action：冻结输入、取消旧请求、给每个服务建立 loading 状态。
    /// UUID 是请求代号；即使服务不及时响应取消，旧结果也不能覆盖新请求。
    func translate() {
        startTranslation(collapseProviders: true)
    }

    /// 展开尚无当前文本结果的翻译源时补查一次；已有结果或正在请求时不重复查询。
    func translateIfNeeded(for provider: TextTranslationProvider) {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              !isTranslating,
              results[provider]?.output == nil
                  || lastRequestContext != currentRequestContext(text: text) else {
            return
        }
        startTranslation(collapseProviders: false)
    }

    /// 冻结本次输入/语言、取消旧任务，再为每个启用来源启动独立任务；各卡片可分别成功或失败。
    private func startTranslation(collapseProviders: Bool) {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            failed = true
            message = AppText.text("请输入需要翻译的文本")
            return
        }

        coordinator.cancel()
        if collapseProviders {
            translationSequence += 1
        }
        failed = false
        let providers = availableProviders
        guard !providers.isEmpty else {
            failed = true
            message = AppText.text("请至少启用一个翻译源")
            coordinator.replaceResults([:])
            return
        }
        message = nil
        let requestedSourceLanguage = sourceLanguage
        // 中英文方向在本地确定后传给服务，避免服务再次检测短词时选择不同方向。
        let resolvedSourceLanguage: String? = requestedSourceLanguage == "auto"
            ? TextLanguageDetector.detect(text)
            : requestedSourceLanguage
        updateAutomaticTargetLanguage()
        let requestSourceLanguage: String
        switch resolvedSourceLanguage {
        case "en-US", "zh-Hans", "zh-Hant":
            requestSourceLanguage = resolvedSourceLanguage ?? requestedSourceLanguage
        default:
            requestSourceLanguage = requestedSourceLanguage
        }
        var resolvedTargetLanguage = targetLanguage
        if resolvedSourceLanguage == resolvedTargetLanguage {
            guard sourceLanguage == "auto" else {
                failed = true
                message = AppText.text("源语言和目标语言不能相同")
                coordinator.replaceResults(Dictionary(uniqueKeysWithValues: providers.map { ($0, .idle) }))
                return
            }
            resolvedTargetLanguage = resolvedSourceLanguage == "zh-Hans"
                || resolvedSourceLanguage == "zh-Hant"
                ? "en-US"
                : "zh-Hans"
            targetLanguage = resolvedTargetLanguage
        }
        lastRequestContext = currentRequestContext(text: text)
        coordinator.start(TextTranslationRequest(text: text, sourceLanguage: requestSourceLanguage,
            targetLanguage: resolvedTargetLanguage), providers: providers)
    }


    /// 只复制该来源的主译文，不录入剪贴板历史；复制失败写入界面错误状态。
    func copyResult(from provider: TextTranslationProvider) {
        guard let translatedText = results[provider]?.output?.primaryText,
              !translatedText.isEmpty else {
            return
        }
        do {
            try clipboardWriter.writeWithoutRecording(.text(translatedText))
            failed = false
            message = AppText.text("译文已复制")
        } catch {
            failed = true
            message = error.localizedDescription
        }
    }

    /// 为原文选择检测语言或指定英/美口音，再交给统一朗读入口。
    func speakSource(accent: String? = nil) {
        let text = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let language = sourceLanguage == "auto"
            ? TextLanguageDetector.detect(text)
            : sourceLanguage
        let spokenLanguage: String? = switch accent {
        case "英": "en-GB"
        case "美": "en-US"
        default: language
        }
        speech.speak(text, language: spokenLanguage)
    }

    /// 按生成译文时的目标语言朗读；设置变更不会改变已保留译文的语言。
    func speakResult(from provider: TextTranslationProvider) {
        guard let text = results[provider]?.output?.primaryText,
              !text.isEmpty else {
            return
        }
        speech.speak(text, language: lastRequestContext?.targetLanguage ?? targetLanguage)
    }

    /// 停止旧请求、交换明确的语言方向并清空旧结果；不会把原文自动替换成某个服务的译文。
    func swapTranslationLanguages() {
        guard canSwapTranslationLanguages, let resolvedSourceLanguage = sourceLanguageForSwap else { return }

        coordinator.cancel()
        let previousTargetLanguage = targetLanguage
        sourceLanguage = previousTargetLanguage
        targetLanguage = resolvedSourceLanguage
        coordinator.replaceResults([:])
        lastRequestContext = nil
        failed = false
        message = nil
    }

    /// 载入历史原文、目标语言与各来源结果，并启用这些来源；不在这里重新请求网络翻译。
    func restore(_ entry: TextTranslationHistoryEntry) {
        coordinator.cancel()
        for provider in entry.results.keys where !enabledProviders.contains(provider) {
            enabledProviders.insert(provider)
        }
        persistProviderConfiguration()
        sourceText = entry.sourceText
        targetLanguage = entry.targetLanguage
        coordinator.replaceResults(entry.results.mapValues(TextTranslationResultState.success))
        lastRequestContext = currentRequestContext(text: entry.sourceText)
        translationSequence += 1
        failed = false
        message = AppText.text("已载入历史记录")
    }

    /// 同时停止请求与朗读，清空输入、结果和消息，避免清空后迟到回包重新填入页面。
    func clearSourceContent() {
        coordinator.cancel()
        speech.stop()
        sourceText = ""
        coordinator.replaceResults([:])
        lastRequestContext = nil
        message = nil
        failed = false
    }

    /// 仅清空当前进程内的翻译历史；不清理系统剪贴板，也不关闭翻译来源。
    func clearHistory() {
        history = []
    }

    func cancel() {
        coordinator.cancel()
        speech.stop()
    }

    /// 自动检测时，中英文始终互译；其他语言或未知输入保留当前目标语言。
    private func updateAutomaticTargetLanguage() {
        guard sourceLanguage == "auto" else { return }
        let automaticTarget: String
        switch detectedSourceLanguageIdentifier {
        case "en-US": automaticTarget = "zh-Hans"
        case "zh-Hans", "zh-Hant": automaticTarget = "en-US"
        default: return
        }
        if targetLanguage != automaticTarget {
            targetLanguage = automaticTarget
        }
    }

    private func currentRequestContext(text: String) -> TranslationRequestContext {
        TranslationRequestContext(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
    }

    /// 以原文和目标语言去重，再限制最近 10 条；数组顺序就是 View 的展示顺序。
    private func insertHistory(
        sourceText: String,
        results: [TextTranslationProvider: TextTranslationOutput],
        targetLanguage: String
    ) {
        history.removeAll {
            $0.sourceText == sourceText
                && $0.targetLanguage == targetLanguage
        }
        history.insert(
            TextTranslationHistoryEntry(
                sourceText: sourceText,
                targetLanguage: targetLanguage,
                results: results
            ),
            at: 0
        )
        history = Array(history.prefix(10))
    }

    /// 只保存来源顺序与启用集合；原文和历史结果不从这条路径落盘。
    private func persistProviderConfiguration() {
        preferencesStore.setProviders(order: providerOrder, enabled: enabledProviders)
    }

}

/// 标识一次翻译请求的输入和语言环境，用于丢弃过期的异步结果。
private struct TranslationRequestContext: Equatable {
    let text: String
    let sourceLanguage: String
    let targetLanguage: String
}
