import Foundation
import MacShared
import TextTranslationFeature
import iSnipsterCore

/// 系统翻译与远程服务的路由。每个窗口注入独立实例，取消只影响该窗口的请求。
@MainActor
public final class TranslationRoutingService: TextTranslationServicing {
    private let apple: AppleTranslationClient
    private let remote: any RemoteTextTranslating
    private var activeRequests: [TextTranslationProvider: UUID] = [:]

    public init(apple: AppleTranslationClient, remote: any RemoteTextTranslating) {
        self.apple = apple
        self.remote = remote
    }

    public func translate(provider: TextTranslationProvider, request: TextTranslationRequest) async throws -> TextTranslationOutput {
        try Task.checkCancellation()
        let id = UUID()
        activeRequests[provider] = id
        defer { if activeRequests[provider] == id { activeRequests[provider] = nil } }
        let output: TextTranslationOutput
        if provider == .apple {
            let results = try await apple.translate(texts: [request.text],
                sourceLanguage: request.sourceLanguage == "auto" ? nil : request.sourceLanguage,
                targetLanguage: request.targetLanguage)
            guard let text = results.first else { throw AppFailure.invalidData(AppText.text(.translationNoResult)) }
            output = .plain(text)
        } else {
            output = try await remote.translate(provider: provider, request: request)
        }
        try Task.checkCancellation()
        guard activeRequests[provider] == id else { throw CancellationError() }
        return output
    }

    public func cancel(provider: TextTranslationProvider) {
        guard activeRequests.removeValue(forKey: provider) != nil else { return }
        if provider == .apple { apple.cancelPendingTranslation() }
    }
}
