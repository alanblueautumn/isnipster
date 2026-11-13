import MacShared
// 阅读路线
// 用 Encodable 请求 DTO 生成 JSON POST，再用 Decodable 响应 DTO 提取译文。
// CodingKeys 类似 Jackson @JsonProperty，把 Swift 驼峰属性映射为服务端 snake_case 字段。
// 官方参考（类型化 JSON 解码）：https://developer.apple.com/documentation/foundation/jsondecoder

import Foundation
import TextTranslationFeature
import iSnipsterCore

/// DeepL 网页翻译接口要求的请求体。
private struct DeepLWebRequest: Encodable {
    /// 随请求发送的应用和系统信息。
    struct AppInformation: Encodable {
        // CodingKey 枚举提供字段映射，类似 Jackson @JsonProperty；不需要手写整份 JSON 字符串。
        enum CodingKeys: String, CodingKey {
            case os
            case osVersion = "os_version"
            case appVersion = "app_version"
            case appBuild = "app_build"
            case instanceID = "instance_id"
        }

        let os: String
        let osVersion: String
        let appVersion: String
        let appBuild: String
        let instanceID: String
    }

    enum CodingKeys: String, CodingKey {
        case text
        case targetLanguage = "target_lang"
        case sourceLanguage = "source_lang"
        case usageType = "usage_type"
        case appInformation = "app_information"
    }

    let text: [String]
    let targetLanguage: String
    let sourceLanguage: String?
    let usageType: String
    let appInformation: AppInformation
}

/// DeepL 网页翻译接口的最小响应数据结构。
private struct DeepLWebResponse: Decodable {
    /// DeepL 返回的一条译文。
    struct Translation: Decodable {
        let text: String?
    }

    let translations: [Translation]?
}

extension RemoteTextTranslationClient {
    /// DeepL 匿名网页翻译接口。请求使用 iSnipster 自身标识，不伪装 DeepL 官方客户端。
    func translateWithDeepL(
        _ request: TextTranslationRequest
    ) async throws -> TextTranslationOutput {
        guard let target = TextTranslationLanguageCode.deepL(
            request.targetLanguage,
            isTarget: true
        ) else {
            throw OperationFailure(category: .unsupportedLanguage, stage: "translation.deepl", message: AppText.text("DeepL 暂不支持当前目标语言"))
        }
        let source = TextTranslationLanguageCode.deepL(
            request.sourceLanguage,
            isTarget: false
        )
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = [
            operatingSystemVersion.majorVersion,
            operatingSystemVersion.minorVersion,
            operatingSystemVersion.patchVersion,
        ].map(String.init).joined(separator: ".")
        let body = DeepLWebRequest(
            text: [request.text],
            targetLanguage: target,
            sourceLanguage: source == "auto" ? nil : source,
            usageType: "translate",
            appInformation: .init(
                os: "macOS",
                osVersion: osVersion,
                appVersion: "1.0",
                appBuild: "1",
                instanceID: deepLInstanceID
            )
        )

        guard let url = URL(string: "https://oneshot-free.www.deepl.com/v1/translate") else {
            throw AppFailure.invalidData("无法创建 DeepL 翻译请求")
        }
        // URLRequest 是可修改的请求值，保存 URL、方法、头与超时；实际发送由 URLSession 完成。
        var urlRequest = URLRequest(url: url, timeoutInterval: 20)
        urlRequest.httpMethod = "POST"
        // Encodable 把值编码为 JSON Data；CodingKeys 可改字段名，Data 才能直接用作 HTTP 请求体。
        urlRequest.httpBody = try JSONEncoder().encode(body)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue("None", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(
            "iSnipster/1.0 (macOS; text translation)",
            forHTTPHeaderField: "User-Agent"
        )
        urlRequest.setValue(osVersion, forHTTPHeaderField: "x-app-os-version")
        urlRequest.setValue(deepLInstanceID, forHTTPHeaderField: "x-app-instance-id")
        urlRequest.setValue(deepLSessionID, forHTTPHeaderField: "x-app-session-id")

        let data = try await responseData(for: urlRequest, providerName: "DeepL")
        let response: DeepLWebResponse
        do {
            // Decodable 按声明的字段类型解码，类似 Jackson DTO；类型不符或必填字段缺失会抛错。
            response = try JSONDecoder().decode(DeepLWebResponse.self, from: data)
        } catch {
            throw OperationFailure(category: .decoding, stage: "translation.decode", message: AppText.text(.deepLDecodeFailed), underlying: error)
        }

        let translatedText = response.translations?.first?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !translatedText.isEmpty else {
            throw AppFailure.invalidData("DeepL 没有返回译文")
        }
        return .plain(translatedText)
    }
}
