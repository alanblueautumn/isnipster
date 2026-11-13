// 阅读路线
// 界面语言选择与文案查询集中在这里；它不同于翻译截图/用户输入的业务功能。
// Bundle/Locale/UserDefaults 分别提供应用资源、语言信息与用户选择；格式化文案保留占位符顺序。
// 官方参考（Locale 语言标识）：https://developer.apple.com/documentation/foundation/locale

import Foundation

/// 应用界面语言的“配置值”。`system` 是延迟解析的策略，而不是某一种具体语言；真正渲染前再依据
/// `Locale.preferredLanguages` 得到 `zhHans` 或 `en`。这相当于 Vue 中将 `locale: 'auto'` 与
/// 实际生效的 `resolvedLocale` 分开，避免把系统偏好固化到用户设置里。
public enum AppUILanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case zhHans
    case en

    /// `UserDefaults` 是 macOS 对轻量偏好的持久化，职责接近浏览器的 localStorage；它不适合存图片等大数据。
    public static let userDefaultsKey = "isnipster.settings.appLanguage"

    public var id: String { rawValue }

    public static var selected: AppUILanguage {
        let rawValue = UserDefaults.standard.string(forKey: userDefaultsKey)
        return rawValue.flatMap(AppUILanguage.init(rawValue:)) ?? .system
    }

    public var resolved: AppUILanguage {
        switch self {
        case .system:
            let preferredLanguage = Locale.preferredLanguages.first ?? ""
            return preferredLanguage.lowercased().hasPrefix("zh") ? .zhHans : .en
        case .zhHans, .en:
            return self
        }
    }

    public var title: String {
        switch self {
        case .system:
            AppText.text(.followSystem)
        case .zhHans:
            AppText.text(.simplifiedChinese)
        case .en:
            "English"
        }
    }

    /// 同时写入本应用的选择和 AppleLanguages。后者由 Foundation 在进程启动时读取，故语言切换约定在下次启动生效。
    public static func prepareForNextLaunch(_ language: AppUILanguage) {
        UserDefaults.standard.set(language.rawValue, forKey: userDefaultsKey)
        switch language {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .zhHans:
            UserDefaults.standard.set(["zh-Hans"], forKey: "AppleLanguages")
        case .en:
            UserDefaults.standard.set(["en"], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }
}

public enum AppText {
    /// 文案放在模块 String Catalog 中；优先使用 Key，未迁移的字符串入口继续保留原文兜底。
    public static var activeLanguage: AppUILanguage {
        AppUILanguage.selected.resolved
    }

    public static func text(_ key: String) -> String {
        localized(Key.legacyKeys[key]?.rawValue ?? key, fallback: key)
    }

    // CVarArg... 是可变参数，类似 Java varargs；%@/%d 等占位符须匹配参数类型，格式串不是类型安全插值。
    public static func format(_ key: String, _ arguments: CVarArg...) -> String {
        NSString(format: text(key), arguments: getVaList(arguments)) as String
    }

    public static func text(_ key: Key) -> String {
        localized(key.rawValue, fallback: key.source)
    }

    public static func format(_ key: Key, _ arguments: CVarArg...) -> String {
        NSString(format: text(key), arguments: getVaList(arguments)) as String
    }

    private static func localized(_ key: String, fallback: String) -> String {
        let bundle = activeLanguage == .en ? englishBundle : chineseBundle
        return bundle.localizedString(forKey: key, value: fallback, table: "Localizable")
    }

    private static let englishBundle = localizedBundle("en")
    private static let chineseBundle = localizedBundle("zh-Hans")

    private static func localizedBundle(_ language: String) -> Bundle {
        guard let path = Bundle.module.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .module }
        return bundle
    }
}
