import Foundation

/// 窗口请求的统一服务入口；保留词典详情，具体服务选择由平台适配器完成。
@MainActor
public protocol TextTranslationServicing: AnyObject {
    func translate(provider: TextTranslationProvider, request: TextTranslationRequest) async throws -> TextTranslationOutput
    func cancel(provider: TextTranslationProvider)
}

/// 系统会话能力与任务控制；调用者不依赖具体翻译框架。
@MainActor
public protocol TranslationSessionControlling: AnyObject {
    func validateLanguages(source: String?, target: String) async throws
    func cancelPendingTranslation()
}
