import Foundation

/// 语言方向是值对象；默认方向与失败重试策略可以分别持有它。
public struct TranslationLanguagePair: Sendable, Equatable {
    public let sourceLanguage: String
    public let targetLanguage: String

    public init(sourceLanguage: String, targetLanguage: String) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

public enum TranslationLanguage {
    public static let settingsIdentifiers = ["en-US", "zh-Hans", "ja-JP", "ko-KR"]
    public static let defaultTextSource = "auto"
    public static let defaultTextTarget = "zh-Hans"
    public static let defaultScreenshotLanguages = TranslationLanguagePair(
        sourceLanguage: "en-US", targetLanguage: "zh-Hans"
    )

    public static func canonicalIdentifier(_ identifier: String) -> String {
        switch identifier {
        case "en": "en-US"
        case "ja": "ja-JP"
        case "ko": "ko-KR"
        case "zh-CN", "zh-SG": "zh-Hans"
        case "zh-TW", "zh-HK": "zh-Hant"
        default: identifier
        }
    }

    public static func settingsIdentifier(_ identifier: String, fallback: String, allowsAutomatic: Bool = false) -> String {
        let canonical = canonicalIdentifier(identifier)
        if allowsAutomatic && canonical == "auto" { return canonical }
        return settingsIdentifiers.contains(canonical) ? canonical : fallback
    }

    /// 系统可用语言可能省略地区；只匹配同语言、同文字体系，不静默改换语言。
    public static func matchingIdentifier(_ identifier: String, supported: [String]) -> String {
        if supported.contains(identifier) { return identifier }
        let requested = Locale.Language(identifier: identifier)
        return supported.first {
            let candidate = Locale.Language(identifier: $0)
            return candidate.languageCode == requested.languageCode && candidate.script == requested.script
        } ?? identifier
    }
}
