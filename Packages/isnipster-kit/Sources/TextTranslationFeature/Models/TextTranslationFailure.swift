import Foundation

public enum TextTranslationFailure: LocalizedError, Sendable {
    case unableToIdentifyLanguage

    public var errorDescription: String? {
        "无法自动检测源语言"
    }
}
