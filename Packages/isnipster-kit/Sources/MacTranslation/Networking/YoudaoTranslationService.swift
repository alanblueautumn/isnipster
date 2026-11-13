import MacShared
// 阅读路线
// 动态密钥 → 请求签名 → 表单 POST → Base64/AES 解码 → 解析译文；词典详情并行补充。
// CryptoKit 的 MD5 与 CommonCrypto 的 AES 用来适配该接口协议，不能照搬为新系统的密码存储方案。
// 官方参考（CryptoKit）：https://developer.apple.com/documentation/cryptokit

import CommonCrypto
import CryptoKit
import Foundation
import TextTranslationFeature
import iSnipsterCore

/// 有道动态密钥接口的响应数据结构。
private struct YoudaoKeyResponse: Decodable {
    /// 加密翻译请求和解密响应所需的密钥材料。
    struct KeyPayload: Decodable {
        let secretKey: String
        let aesKey: String
        let aesIv: String
    }

    let data: KeyPayload
    let code: Int
    let msg: String
}

extension RemoteTextTranslationClient {
    /// 有道网页翻译：先动态获取签名与 AES 参数，再提交翻译并解密响应。
    func translateWithYoudao(
        _ request: TextTranslationRequest
    ) async throws -> TextTranslationOutput {
        guard let source = TextTranslationLanguageCode.youdao(request.sourceLanguage),
              let target = TextTranslationLanguageCode.youdao(request.targetLanguage) else {
            throw OperationFailure(category: .unsupportedLanguage, stage: "translation.youdao", message: AppText.text("有道翻译暂不支持当前语言"))
        }

        // 词典详情与主翻译并行请求。详情接口失败时仍返回主译文，避免部分失败
        // 把整个有道结果卡片变成失败状态。
        async let dictionaryDetails = fetchYoudaoDictionaryDetails(request)
        let key = try await fetchYoudaoKey()
        guard key.code == 0 else {
            throw AppFailure.operationFailed("有道密钥请求失败：\(key.msg)")
        }

        let timestamp = String(Int(Date().timeIntervalSince1970 * 1_000))
        var parameters = youdaoBaseParameters
        parameters["i"] = request.text
        parameters["from"] = source
        parameters["to"] = target
        parameters["dictResult"] = "false"
        parameters["keyid"] = "webfanyi"
        parameters["mysticTime"] = timestamp
        parameters["sign"] = youdaoSign(timestamp: timestamp, key: key.data.secretKey)

        guard let url = URL(string: "https://dict.youdao.com/webtranslate") else {
            throw AppFailure.invalidData("无法创建有道翻译请求")
        }
        // URLRequest 是可修改的请求值，保存 URL、方法、头与超时；实际发送由 URLSession 完成。
        var urlRequest = URLRequest(url: url, timeoutInterval: 20)
        urlRequest.httpMethod = "POST"
        urlRequest.httpBody = formBody(parameters)
        applyYoudaoHeaders(to: &urlRequest)
        urlRequest.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )

        let encryptedData = try await responseData(for: urlRequest, providerName: "有道")
        guard let encryptedText = String(data: encryptedData, encoding: .utf8) else {
            throw AppFailure.invalidData("有道返回的数据无法读取")
        }
        let decryptedData = try decryptYoudaoResponse(
            encryptedText,
            key: key.data.aesKey,
            iv: key.data.aesIv
        )

        let translatedText = try parseYoudaoTranslation(decryptedData)
        let details: TextTranslationOutput.Details
        do {
            details = try await dictionaryDetails
        } catch {
            if Task.isCancelled { throw CancellationError() }
            // 可选词典失败不影响主译文；日志保留诊断，正文不落日志。
            AppDiagnostics.failure(error, stage: "translation.youdao.dictionary")
            details = .empty
        }
        try Task.checkCancellation()
        return TextTranslationOutput(primaryText: translatedText, details: details)
    }

    private var youdaoBaseParameters: [String: String] {
        [
            "client": "fanyideskweb",
            "product": "webfanyi",
            "appVersion": "1.0.0",
            "vendor": "web",
            "pointParam": "client,mysticTime,product",
            "keyfrom": "fanyi.web",
            "keyid": "",
            "sign": "",
            "mysticTime": "",
        ]
    }

    private func fetchYoudaoKey() async throws -> YoudaoKeyResponse {
        let timestamp = String(Int(Date().timeIntervalSince1970 * 1_000))
        var parameters = youdaoBaseParameters
        parameters["keyid"] = "webfanyi-key-getter"
        parameters["mysticTime"] = timestamp
        parameters["sign"] = youdaoSign(
            timestamp: timestamp,
            key: "asdjnjfenknafdfsdfsd"
        )

        // URLComponents 分开管理路径与查询参数，再生成转义后的 URL；类似后端 URI builder。
        var components = URLComponents(string: "https://dict.youdao.com/webtranslate/key")
        components?.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else {
            throw AppFailure.invalidData("无法创建有道密钥请求")
        }

        var urlRequest = URLRequest(url: url, timeoutInterval: 20)
        applyYoudaoHeaders(to: &urlRequest)
        let data = try await responseData(for: urlRequest, providerName: "有道")
        do {
            // Decodable 按声明的字段类型解码，类似 Jackson DTO；类型不符或必填字段缺失会抛错。
            return try JSONDecoder().decode(YoudaoKeyResponse.self, from: data)
        } catch {
            throw OperationFailure(category: .decoding, stage: "translation.decode", message: AppText.text(.youdaoKeyDecodeFailed), underlying: error)
        }
    }

    // inout 表示修改调用者传入的值；调用时写 &urlRequest，类似显式的可变借用，不是返回新请求。
    func applyYoudaoHeaders(to request: inout URLRequest) {
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("https://fanyi.youdao.com", forHTTPHeaderField: "Referer")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/605.1.15 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "OUTFOX_SEARCH_USER_ID=1796239350@10.110.96.157;",
            forHTTPHeaderField: "Cookie"
        )
    }

    private func youdaoSign(timestamp: String, key: String) -> String {
        let value = "client=fanyideskweb&mysticTime=\(timestamp)&product=webfanyi&key=\(key)"
        return md5(value)
    }

    func md5(_ value: String) -> String {
        Insecure.MD5.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    func formBody(_ parameters: [String: String]) -> Data? {
        var components = URLComponents()
        components.queryItems = parameters
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        let form = components.percentEncodedQuery?
            .replacingOccurrences(of: "%20", with: "+")
        return form?.data(using: .utf8)
    }

    /// 有道会在成功、风控和参数错误时返回不同字段集合，因此不能让固定 Codable
    /// 模型先于业务错误码失败。这里先读取错误码，再递归收集所有 tgt 字段。
    private func parseYoudaoTranslation(_ data: Data) throws -> String {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw OperationFailure(category: .decoding, stage: "translation.youdao.decode", message: AppText.text(.youdaoJSONFailed), underlying: error)
        }
        guard let object = json as? [String: Any] else {
            throw AppFailure.invalidData("有道返回的数据结构无效")
        }

        let code = (object["code"] as? Int)
            ?? (object["code"] as? NSNumber)?.intValue
            ?? (object["code"] as? String).flatMap(Int.init)
        if let code, code != 0 {
            let serverMessage = object["msg"] as? String
                ?? object["message"] as? String
            let suffix = serverMessage.flatMap { $0.isEmpty ? nil : "：\($0)" } ?? ""
            throw AppFailure.operationFailed("有道翻译失败（代码 \(code)）\(suffix)")
        }

        var translations: [String] = []
        collectYoudaoTargets(from: object["translateResult"], into: &translations)
        if translations.isEmpty, let fallback = object["translation"] as? [String] {
            translations = fallback
        }
        let translatedText = translations
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translatedText.isEmpty else {
            throw AppFailure.invalidData("有道没有返回译文")
        }
        return translatedText
    }

    private func collectYoudaoTargets(from value: Any?, into results: inout [String]) {
        if let object = value as? [String: Any] {
            if let target = object["tgt"] as? String, !target.isEmpty {
                results.append(target)
            }
            for nestedValue in object.values {
                collectYoudaoTargets(from: nestedValue, into: &results)
            }
            return
        }
        if let array = value as? [Any] {
            for nestedValue in array {
                collectYoudaoTargets(from: nestedValue, into: &results)
            }
        }
    }

    private func decryptYoudaoResponse(
        _ encryptedText: String,
        key: String,
        iv: String
    ) throws -> Data {
        var base64 = encryptedText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // URL-safe Base64 先还原字符表，再补齐 4 字节编码组需要的等号；这一步不是 AES 解密本身。
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let encryptedData = Data(base64Encoded: base64) else {
            throw AppFailure.invalidData("有道加密响应不是有效的 Base64")
        }

        let keyDigest = Data(Insecure.MD5.hash(data: Data(key.utf8)))
        let ivDigest = Data(Insecure.MD5.hash(data: Data(iv.utf8)))
        // AES 分组解密预留一个分组的额外空间；CCCrypt 通过 outputLength 回传真正写入的字节数。
        let outputCapacity = encryptedData.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0

        // 临时借用可写字节缓冲给 C API；指针只在闭包执行期间有效，不得存起来供异步回调使用。
        let status = output.withUnsafeMutableBytes { outputBytes in
            // 临时借用只读字节给 C API；Swift 管理底层存储，裸指针不能越过这个闭包的生命周期。
            encryptedData.withUnsafeBytes { encryptedBytes in
                keyDigest.withUnsafeBytes { keyBytes in
                    ivDigest.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            keyDigest.count,
                            ivBytes.baseAddress,
                            encryptedBytes.baseAddress,
                            encryptedData.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw AppFailure.invalidData("有道响应解密失败（代码 \(status)）")
        }
        // 去掉预分配但未使用的尾部，避免将缓冲中的零字节一并交给 JSON 解析器。
        output.removeSubrange(outputLength ..< output.count)
        return output
    }
}
