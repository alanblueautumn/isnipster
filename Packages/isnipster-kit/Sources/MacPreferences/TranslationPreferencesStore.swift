import Foundation
import TextTranslationFeature
import iSnipsterCore

/// 开始一次操作时读取的值快照，不携带 UserDefaults 或界面状态。
public struct TranslationPreferencesSnapshot: Sendable {
    public let textSourceLanguage: String
    public let textTargetLanguage: String
    public let screenshotLanguages: TranslationLanguagePair
    public let screenshotTimeoutSeconds: Int
    public let providerOrder: [TextTranslationProvider]
    public let enabledProviders: Set<TextTranslationProvider>

    public init(textSourceLanguage: String, textTargetLanguage: String,
                screenshotLanguages: TranslationLanguagePair, screenshotTimeoutSeconds: Int,
                providerOrder: [TextTranslationProvider], enabledProviders: Set<TextTranslationProvider>) {
        self.textSourceLanguage = textSourceLanguage
        self.textTargetLanguage = textTargetLanguage
        self.screenshotLanguages = screenshotLanguages
        self.screenshotTimeoutSeconds = screenshotTimeoutSeconds
        self.providerOrder = providerOrder
        self.enabledProviders = enabledProviders
    }
}

@MainActor
public protocol TranslationPreferencesStoring: AnyObject {
    func load() -> TranslationPreferencesSnapshot
    func setTextSourceLanguage(_ language: String)
    func setTextTargetLanguage(_ language: String)
    func setScreenshotSourceLanguage(_ language: String)
    func setScreenshotTargetLanguage(_ language: String)
    func setProviders(order: [TextTranslationProvider], enabled: Set<TextTranslationProvider>)
}

/// 仅保存翻译配置；原文、截图和翻译结果不进入偏好存储。
@MainActor
public final class UserDefaultsTranslationPreferencesStore: TranslationPreferencesStoring {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func load() -> TranslationPreferencesSnapshot {
        let preferences = AppPreferences.Translation.self
        let rawOrder = defaults.stringArray(forKey: preferences.providerOrderKey) ?? []
        let order = rawOrder.compactMap(TextTranslationProvider.init(rawValue:))
            .reduce(into: [TextTranslationProvider]()) { providers, provider in
                if !providers.contains(provider) { providers.append(provider) }
            }
        let enabled: Set<TextTranslationProvider>
        if defaults.object(forKey: preferences.enabledProvidersKey) == nil {
            enabled = [.youdao, .google]
        } else {
            enabled = Set((defaults.stringArray(forKey: preferences.enabledProvidersKey) ?? [])
                .compactMap(TextTranslationProvider.init(rawValue:)))
        }
        let range = preferences.screenshotTimeoutRange
        return TranslationPreferencesSnapshot(
            textSourceLanguage: TranslationLanguage.settingsIdentifier(
                preferences.source.read(from: defaults), fallback: preferences.source.defaultValue,
                allowsAutomatic: true),
            textTargetLanguage: TranslationLanguage.settingsIdentifier(
                preferences.target.read(from: defaults), fallback: preferences.target.defaultValue),
            screenshotLanguages: preferences.screenshotLanguages(defaults: defaults),
            screenshotTimeoutSeconds: min(max(preferences.screenshotTimeoutSeconds.read(from: defaults),
                                             range.lowerBound), range.upperBound),
            providerOrder: order + TextTranslationProvider.allCases.filter { !order.contains($0) },
            enabledProviders: enabled
        )
    }

    public func setTextSourceLanguage(_ language: String) {
        defaults.set(language, forKey: AppPreferences.Translation.source.name)
    }

    public func setTextTargetLanguage(_ language: String) {
        defaults.set(language, forKey: AppPreferences.Translation.target.name)
    }

    public func setScreenshotSourceLanguage(_ language: String) {
        defaults.set(language, forKey: AppPreferences.Translation.screenshotSource.name)
    }

    public func setScreenshotTargetLanguage(_ language: String) {
        defaults.set(language, forKey: AppPreferences.Translation.screenshotTarget.name)
    }

    public func setProviders(order: [TextTranslationProvider], enabled: Set<TextTranslationProvider>) {
        defaults.set(order.map(\.rawValue), forKey: AppPreferences.Translation.providerOrderKey)
        defaults.set(order.filter(enabled.contains).map(\.rawValue),
                     forKey: AppPreferences.Translation.enabledProvidersKey)
    }
}
