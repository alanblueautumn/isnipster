import Foundation
import ClipboardFeature
import iSnipsterCore

/// 配置键和缺省值的唯一声明；UI 的 AppStorage 与策略快照共同使用。
public struct AppPreferenceKey<Value: Sendable>: Sendable {
    public let name: String
    public let defaultValue: Value

    public init(_ name: String, defaultValue: Value) {
        self.name = name
        self.defaultValue = defaultValue
    }
}

public extension AppPreferenceKey where Value == Bool {
    func read(from defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: name) == nil ? defaultValue : defaults.bool(forKey: name)
    }
}

public extension AppPreferenceKey where Value == Int {
    func read(from defaults: UserDefaults = .standard) -> Int {
        defaults.object(forKey: name) == nil ? defaultValue : defaults.integer(forKey: name)
    }
}

public extension AppPreferenceKey where Value == String {
    func read(from defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: name) ?? defaultValue
    }
}

public enum AppPreferences {
    public enum Clipboard {
        public static let suppressesDirectPastePermissionPrompt = AppPreferenceKey<Bool>("isnipster.settings.suppressesDirectPastePermissionPrompt", defaultValue: false)
        public static let recordsClipboardHistory = AppPreferenceKey<Bool>("isnipster.settings.recordsClipboardHistory", defaultValue: true)
        public static let clipboardHistoryLimit = AppPreferenceKey<Int>("isnipster.settings.clipboardHistoryLimit", defaultValue: 200)
        public static let clipboardRetentionDays = AppPreferenceKey<Int>("isnipster.settings.clipboardRetentionDays", defaultValue: 30)
        public static let clearsExpiredClipboardItems = AppPreferenceKey<Bool>("isnipster.settings.clearsExpiredClipboardItems", defaultValue: true)
        public static let recordsClipboardText = AppPreferenceKey<Bool>("isnipster.settings.recordsClipboardText", defaultValue: true)
        public static let recordsClipboardImages = AppPreferenceKey<Bool>("isnipster.settings.recordsClipboardImages", defaultValue: true)
        public static let recordsClipboardFiles = AppPreferenceKey<Bool>("isnipster.settings.recordsClipboardFiles", defaultValue: true)
        public static let recordsClipboardColors = AppPreferenceKey<Bool>("isnipster.settings.recordsClipboardColors", defaultValue: false)
        public static let removesDuplicates = AppPreferenceKey<Bool>("isnipster.settings.removesDuplicates", defaultValue: true)

        public static func currentPolicy(defaults: UserDefaults = .standard) -> ClipboardHistoryPolicy {
            let days = clipboardRetentionDays.read(from: defaults)
            return ClipboardHistoryPolicy(
                recordsHistory: recordsClipboardHistory.read(from: defaults),
                maximumItems: clipboardHistoryLimit.read(from: defaults),
                retentionDays: clearsExpiredClipboardItems.read(from: defaults) && days > 0 ? days : nil,
                recordsText: recordsClipboardText.read(from: defaults),
                recordsImages: recordsClipboardImages.read(from: defaults),
                recordsFiles: recordsClipboardFiles.read(from: defaults),
                recordsColors: recordsClipboardColors.read(from: defaults),
                removesDuplicates: removesDuplicates.read(from: defaults)
            )
        }
    }

    public enum Translation {
        public static let target = AppPreferenceKey<String>("isnipster.translationTarget", defaultValue: TranslationLanguage.defaultTextTarget)
        public static let source = AppPreferenceKey<String>("isnipster.textTranslationSourceLanguage.v1", defaultValue: TranslationLanguage.defaultTextSource)
        // 保留已发布版本保存键；默认方向和备用策略在内存模型中分别命名。
        public static let screenshotSource = AppPreferenceKey<String>("isnipster.screenshotTranslationFallbackSource", defaultValue: TranslationLanguage.defaultScreenshotLanguages.sourceLanguage)
        public static let screenshotTarget = AppPreferenceKey<String>("isnipster.screenshotTranslationFallbackTarget", defaultValue: TranslationLanguage.defaultScreenshotLanguages.targetLanguage)
        public static let screenshotTimeoutSeconds = AppPreferenceKey<Int>("isnipster.screenshotTranslationTimeoutSeconds", defaultValue: 30)
        public static let screenshotTimeoutRange = 5...120
        public static let providerOrderKey = "isnipster.textTranslationProviderOrder.v1"
        public static let enabledProvidersKey = "isnipster.textTranslationEnabledProviders.v1"

        public static func screenshotLanguages(defaults: UserDefaults = .standard) -> TranslationLanguagePair {
            let source = TranslationLanguage.settingsIdentifier(screenshotSource.read(from: defaults), fallback: screenshotSource.defaultValue)
            let target = TranslationLanguage.settingsIdentifier(screenshotTarget.read(from: defaults), fallback: screenshotTarget.defaultValue)
            return TranslationLanguagePair(sourceLanguage: source, targetLanguage:
                target != source ? target : (source == "zh-Hans" ? "en-US" : "zh-Hans"))
        }
    }
}
