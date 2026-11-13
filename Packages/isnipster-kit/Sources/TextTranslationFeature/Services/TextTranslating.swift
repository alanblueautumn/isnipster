import Foundation

/// 抽象批量文本翻译能力，由需要 UI 会话的平台客户端实现。
@MainActor
public protocol TextTranslating: AnyObject {
    // Apple TranslationSession 由 SwiftUI 生命周期提供，因此翻译端口属于 MainActor。
    func translate(texts: [String], sourceLanguage: String?, targetLanguage: String) async throws -> [String]
}

