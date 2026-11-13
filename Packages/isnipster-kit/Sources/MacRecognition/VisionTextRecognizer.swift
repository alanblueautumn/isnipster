import MacShared
import RecognitionFeature
// 阅读路线
// 创建 VNRecognizeTextRequest → VNImageRequestHandler 同步执行 → 转成项目 OCR DTO。
// 字符范围使用 Swift String.Index；缺少精确字框时记录估算标记，打码层据此决定能否局部遮盖。
// 官方参考（Vision 文字识别）：https://developer.apple.com/documentation/vision/recognizing-text-in-images

import Foundation
import iSnipsterCore
import Vision

// Vision 是 Apple 的本地视觉框架，OCR 输出文字与归一化矩形。
// perform 是同步耗时调用，放在独立 actor 执行；取消外层 Task 不会强制中断该系统调用。

/// Vision OCR 在本机执行。actor 保证同一实例不会并发复用 Vision request 状态。
///
/// Java 对照：actor 类似串行 mailbox 的 Service，但不固定绑定某一条线程；调用 recognize 需要 await，
/// 但同步的 `handler.perform` 会在该 actor 的执行域中完成，不会并发污染 request。
public actor VisionTextRecognizer: TextRecognizing {
    public init() {}

    public func recognize(image: RasterImage, languages: [String]) async throws -> [OCRTextRegion] {
        // Request 是一次性命令对象：配置识别策略 -> Handler 执行 -> 从 results 读结果。
        // VNRecognizeTextRequest 是 Vision 的可配置一次性任务；它不是网络请求，默认在设备本机运行。
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.recognitionLanguages = languages

        do {
            // VNImageRequestHandler 把 CGImage 适配给 Vision。`perform` 是同步 API，故整个识别器放在 actor 内隔离。
            let handler = VNImageRequestHandler(cgImage: image.cgImage, options: [:])
            try handler.perform([request])
        } catch {
            throw AppFailure.operationFailed(AppText.format("OCR 识别失败：%@", error.localizedDescription))
        }

        // `?? []` 是 nil 合并运算符；compactMap 同时完成 DTO 转换和无效结果过滤。
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, candidate.confidence >= 0.25 else { return nil }
            let characterRanges = Self.characterRanges(
                in: candidate.string,
                trimmedText: text
            )
            // Vision 的 normalized boundingBox 取值是 0...1 且原点在左下；渲染到 AppKit/CGImage 前需要调用方转换坐标。
            let fallbackRect = observation.boundingBox
            let characterCount = max(characterRanges.count, 1)
            let characters = characterRanges.enumerated().map { offset, element in
                let normalizedRect: CGRect
                let hasPreciseBounds: Bool
                if let characterBox = try? candidate.boundingBox(for: element.range) {
                    normalizedRect = characterBox.boundingBox
                    hasPreciseBounds = true
                } else {
                    hasPreciseBounds = false
                    let width = fallbackRect.width / CGFloat(characterCount)
                    normalizedRect = CGRect(
                        x: fallbackRect.minX + CGFloat(offset) * width,
                        y: fallbackRect.minY,
                        width: width,
                        height: fallbackRect.height
                    )
                }
                return OCRCharacterRegion(
                    text: element.text,
                    normalizedRect: normalizedRect,
                    hasPreciseBounds: hasPreciseBounds
                )
            }
            return OCRTextRegion(
                text: text,
                confidence: candidate.confidence,
                normalizedRect: observation.boundingBox,
                characters: characters
            )
        }
    }

    // nonisolated 表示不读取 actor 实例状态，纯字符串运算无需切入 actor；不等于创建后台线程。
    private nonisolated static func characterRanges(
        in source: String,
        trimmedText: String
    ) -> [(text: String, range: Range<String.Index>)] {
        guard let trimmedRange = source.range(of: trimmedText) else { return [] }
        var result: [(text: String, range: Range<String.Index>)] = []
        var index = trimmedRange.lowerBound
        while index < trimmedRange.upperBound {
            let next = source.index(after: index)
            let range = index..<next
            result.append((String(source[range]), range))
            index = next
        }
        return result
    }
}
