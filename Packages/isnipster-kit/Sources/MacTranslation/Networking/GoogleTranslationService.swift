import MacShared
// 阅读路线
// 构造 query 参数 → URLSession 请求 → Decodable 解码 → 拼接分句译文。
// URLComponents 负责参数转义，不能直接拼接用户文本；此处使用网页接口，响应约定可能变化。
// 官方参考（URLComponents 查询参数）：https://developer.apple.com/documentation/foundation/urlcomponents

import Foundation
import TextTranslationFeature
import iSnipsterCore

/// Google 网页翻译接口的最小响应数据结构。
private struct GoogleTranslationResponse: Decodable {
    /// 一段译文；Google 可能把一次请求拆成多个句段返回。
    struct Sentence: Decodable {
        let trans: String?
    }

    let sentences: [Sentence]?
}

extension RemoteTextTranslationClient {
    /// Google 网页翻译的 GTX JSON 接口，与浏览器翻译结果结构一致，不提供稳定性承诺。
    func translateWithGoogle(
        _ request: TextTranslationRequest
    ) async throws -> TextTranslationOutput {
        guard let source = TextTranslationLanguageCode.google(request.sourceLanguage),
              let target = TextTranslationLanguageCode.google(request.targetLanguage) else {
            throw OperationFailure(category: .unsupportedLanguage, stage: "translation.google", message: AppText.text("Google 翻译暂不支持当前语言"))
        }

        // URLComponents 分开管理路径与查询参数，再生成转义后的 URL；类似后端 URI builder。
        var components = URLComponents(string: "https://translate.google.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "q", value: request.text),
            URLQueryItem(name: "sl", value: source),
            URLQueryItem(name: "tl", value: target),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "dj", value: "1"),
            URLQueryItem(name: "ie", value: "UTF-8"),
            URLQueryItem(name: "client", value: "gtx"),
        ]
        guard let url = components?.url else {
            throw AppFailure.invalidData("无法创建 Google 翻译请求")
        }

        // URLRequest 是可修改的请求值，保存 URL、方法、头与超时；实际发送由 URLSession 完成。
        var urlRequest = URLRequest(url: url, timeoutInterval: 20)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(
            "iSnipster/1.0 (macOS; text translation)",
            forHTTPHeaderField: "User-Agent"
        )

        let data = try await responseData(for: urlRequest, providerName: "Google")
        let response: GoogleTranslationResponse
        do {
            // Decodable 按声明的字段类型解码，类似 Jackson DTO；类型不符或必填字段缺失会抛错。
            response = try JSONDecoder().decode(GoogleTranslationResponse.self, from: data)
        } catch {
            throw OperationFailure(category: .decoding, stage: "translation.decode", message: AppText.text(.googleDecodeFailed), underlying: error)
        }

        let translatedText = response.sentences?
            .compactMap(\.trans)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !translatedText.isEmpty else {
            throw AppFailure.invalidData("Google 没有返回译文")
        }
        return .plain(translatedText)
    }
}
