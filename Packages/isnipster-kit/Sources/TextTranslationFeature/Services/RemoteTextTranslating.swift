import Foundation

/// 在线翻译端口。Feature 定义业务请求和结果，平台层负责 HTTP 与供应商格式。
public protocol RemoteTextTranslating: Sendable {
    func translate(
        provider: TextTranslationProvider,
        request: TextTranslationRequest
    ) async throws -> TextTranslationOutput
}
