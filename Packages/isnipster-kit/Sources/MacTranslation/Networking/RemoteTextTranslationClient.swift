import MacShared
// 阅读路线
// 根据 provider 路由在线请求，统一验证 HTTP 状态，并集中转换各服务的语言代码。
// URLSession 类似 Java HttpClient；它返回 Data 与响应对象，HTTP 4xx/5xx 需要自行判断。
// 官方参考（URLSession 异步网络请求）：https://developer.apple.com/documentation/foundation/urlsession

import Foundation
import TextTranslationFeature
import iSnipsterCore

/// Google、有道和 DeepL 在线翻译的统一入口。
///
/// 客户端不保存业务原文属性；每次按 provider 发送当前请求并返回 DTO。
/// URLSession 的缓存由注入的 session 配置决定，不能把“无原文属性”等同于“网络层完全不缓存”。
public actor RemoteTextTranslationClient: RemoteTextTranslating {
    let session: URLSession
    let deepLInstanceID = UUID().uuidString.lowercased()
    let deepLSessionID = UUID().uuidString.lowercased()

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func translate(
        provider: TextTranslationProvider,
        request: TextTranslationRequest
    ) async throws -> TextTranslationOutput {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppFailure.invalidData("翻译文本不能为空")
        }

        return switch provider {
        case .google:
            try await translateWithGoogle(request)
        case .youdao:
            try await translateWithYoudao(request)
        case .deepL:
            try await translateWithDeepL(request)
        case .apple:
            throw AppFailure.unavailable("Apple Translation 不使用在线翻译客户端")
        }
    }

    func responseData(for request: URLRequest, providerName: String) async throws -> Data {
        do {
            // 元组解构同时取得响应体与元数据；await 期间 actor 可处理其他请求，actor 不是整段方法持锁执行。
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw AppFailure.invalidData("\(providerName) 返回了无效响应")
            }
            guard (200 ..< 300).contains(response.statusCode) else {
                throw OperationFailure(
                    category: .network, stage: "translation.http",
                    message: AppText.format(.requestHTTPFailed, providerName, response.statusCode),
                    underlying: NSError(domain: "HTTP", code: response.statusCode)
                )
            }
            return data
        } catch {
            if Task.isCancelled || TaskCancellation.isCancellation(error) { throw CancellationError() }
            if error is AppFailure || error is OperationFailure { throw error }
            throw OperationFailure(
                category: .network, stage: "translation.http",
                message: AppText.format(.requestFailed, providerName, error.localizedDescription), underlying: error
            )
        }
    }
}

/// 集中负责把应用内部语言标识转换为各在线翻译源使用的代码。
enum TextTranslationLanguageCode {
    static func google(_ identifier: String) -> String? {
        switch identifier {
        case "auto": "auto"
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        case "en", "en-US", "en-GB": "en"
        case "ja", "ja-JP": "ja"
        case "ko", "ko-KR": "ko"
        default: nil
        }
    }

    static func youdao(_ identifier: String) -> String? {
        switch identifier {
        case "auto": "auto"
        case "zh-Hans": "zh-CHS"
        case "zh-Hant": "zh-CHT"
        case "en", "en-US", "en-GB": "en"
        case "ja", "ja-JP": "ja"
        case "ko", "ko-KR": "ko"
        default: nil
        }
    }

    static func deepL(_ identifier: String, isTarget: Bool) -> String? {
        switch identifier {
        case "auto": isTarget ? nil : "auto"
        case "zh-Hans": "zh-Hans"
        case "zh-Hant": "zh-Hant"
        case "en", "en-US": isTarget ? "en-US" : "en"
        case "en-GB": isTarget ? "en-GB" : "en"
        case "ja", "ja-JP": "ja"
        case "ko", "ko-KR": "ko"
        default: nil
        }
    }
}
