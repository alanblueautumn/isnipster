// 阅读路线
// 备用语言只处理自动检测失败；ImageTranslationResult 同时返回译图和实际启用的备用组合。
// Optional 的 nil 表示本次没启用备用方向，让 UI 可以区分正常翻译与降级重试。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import Foundation
import iSnipsterCore

/// 自动识别失败时使用的明确语言组合，只作用于截图翻译。
public struct ScreenshotTranslationFallback: Sendable {
    public static let supportedLanguageIdentifiers = TranslationLanguage.settingsIdentifiers

    public let languages: TranslationLanguagePair
    public var sourceLanguage: String { languages.sourceLanguage }
    public var targetLanguage: String { languages.targetLanguage }

    public init(
        sourceLanguage: String = TranslationLanguage.defaultScreenshotLanguages.sourceLanguage,
        targetLanguage: String = TranslationLanguage.defaultScreenshotLanguages.targetLanguage
    ) {
        languages = TranslationLanguagePair(sourceLanguage: sourceLanguage, targetLanguage: targetLanguage)
    }

    public init(languages: TranslationLanguagePair) {
        self.languages = languages
    }
}

/// 把实际启用的备用组合带回界面，避免副工具栏仍显示旧的翻译方向。
public struct ImageTranslationResult: Sendable {
    public let image: RasterImage
    public let appliedFallback: ScreenshotTranslationFallback?

    public init(image: RasterImage, appliedFallback: ScreenshotTranslationFallback?) {
        self.image = image
        self.appliedFallback = appliedFallback
    }
}

