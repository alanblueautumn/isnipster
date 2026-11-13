import MacShared
// 阅读路线
// 按请求语言查询词典补充信息；主翻译成功时，词典部分失败可降级为空详情。
// 这是同一服务来源的补充请求，不能把它的失败与主译文失败视为同一状态。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import Foundation
import TextTranslationFeature
import iSnipsterCore

/// 为在线翻译客户端补充有道词典详情查询能力。
extension RemoteTextTranslationClient {
    /// 获取单词的音标、释义、词形、考试类型和常用短语。
    /// 句子和过长文本不请求词典接口，避免返回无意义的空详情。
    func fetchYoudaoDictionaryDetails(
        _ translationRequest: TextTranslationRequest
    ) async throws -> TextTranslationOutput.Details {
        guard translationRequest.text.count <= 80,
              let foreignLanguage = youdaoDictionaryLanguage(
                  sourceLanguage: translationRequest.sourceLanguage,
                  targetLanguage: translationRequest.targetLanguage
              ) else {
            return .empty
        }

        let signingText = "\(translationRequest.text)webdict"
        let time = signingText.count % 10
        let salt = md5(signingText)
        let sign = md5(
            "web\(translationRequest.text)\(time)Mk6hqtUp33DGGtoS63tTJbMUYjRrG1Lu\(salt)"
        )
        // URLComponents 分开管理路径与查询参数，再生成转义后的 URL；类似后端 URI builder。
        var components = URLComponents(string: "https://dict.youdao.com/jsonapi_s")
        components?.queryItems = [
            URLQueryItem(name: "doctype", value: "json"),
            URLQueryItem(name: "jsonversion", value: "4"),
        ]
        guard let url = components?.url else {
            throw AppFailure.invalidData("无法创建有道词典请求")
        }

        // URLRequest 是可修改的请求值，保存 URL、方法、头与超时；实际发送由 URLSession 完成。
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.httpBody = formBody([
            "q": translationRequest.text,
            "le": foreignLanguage,
            "client": "web",
            "t": String(time),
            "sign": sign,
            "keyfrom": "webdict",
        ])
        applyYoudaoHeaders(to: &request)
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )

        let data = try await responseData(for: request, providerName: "有道词典")
        do {
            return try JSONDecoder()
                .decode(YoudaoDictionaryResponse.self, from: data)
                .details(query: translationRequest.text)
        } catch {
            throw OperationFailure(category: .decoding, stage: "translation.decode", message: AppText.text(.youdaoDictionaryDecodeFailed), underlying: error)
        }
    }

    private func youdaoDictionaryLanguage(
        sourceLanguage: String,
        targetLanguage: String
    ) -> String? {
        let sourceIsChinese = sourceLanguage == "zh-Hans" || sourceLanguage == "zh-Hant"
        let targetIsChinese = targetLanguage == "zh-Hans" || targetLanguage == "zh-Hant"
        if targetIsChinese, !sourceIsChinese {
            return youdaoDictionaryCode(sourceLanguage)
        }
        if sourceIsChinese, !targetIsChinese {
            return youdaoDictionaryCode(targetLanguage)
        }
        return nil
    }

    private func youdaoDictionaryCode(_ identifier: String) -> String? {
        switch identifier {
        case "en", "en-US", "en-GB": "en"
        case "ja", "ja-JP": "ja"
        case "ko", "ko-KR": "ko"
        default: nil
        }
    }
}
