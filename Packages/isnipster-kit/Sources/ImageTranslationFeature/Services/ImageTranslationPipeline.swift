import TextTranslationFeature
import RecognitionFeature
// 阅读路线
// 按 OCR → 文本翻译 → 区域配对 → 图片渲染串联三个接口，像 Java Application Service 编排多个 Gateway。
// 下标是文本和区域的关联关系；数量不符必须停止，不能用 zip 静默丢失尾部结果。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import iSnipsterCore

/// 图片内翻译的领域编排。
///
/// OCR、翻译和重绘通过三个协议连接；本类负责调用顺序与数据配对，
/// 具体系统 API 和绘制算法留在协议实现中。
///
/// Java 对照：这是典型的 Facade/Application Service。数组元素始终按下标一一对应，
/// 所以翻译后会校验数量，再把文字和坐标重新组合成 DTO。
@MainActor
public final class ImageTranslationPipeline {
    private let recognizer: any TextRecognizing
    private let translator: any TextTranslating
    private let renderer: any ImageTranslationRendering

    public init(
        recognizer: any TextRecognizing,
        translator: any TextTranslating,
        renderer: any ImageTranslationRendering
    ) {
        self.recognizer = recognizer
        self.translator = translator
        self.renderer = renderer
    }

    public func translate(
        image: RasterImage,
        recognitionImage: RasterImage? = nil,
        recognitionLanguages: [String] = ["zh-Hans", "en-US"],
        sourceLanguage: String? = nil,
        targetLanguage: String,
        fallback: ScreenshotTranslationFallback
    ) async throws -> ImageTranslationResult {
        // 整条流程虽然从 MainActor 发起，但 await actor 实现时不会占用 UI 线程。
        let recognized = try await recognizer.recognize(
            // recognitionImage 可以是同比例缩小图；OCR 返回归一化坐标，最终渲染仍
            // 使用上面的 full-resolution image，不会降低截图输出清晰度。
            image: recognitionImage ?? image,
            languages: recognitionLanguages
        )

        guard !recognized.isEmpty else {
            throw AppFailure.invalidData("所选区域没有识别到可翻译文字")
        }
        try Task.checkCancellation()

        // `recognized.map(\.text)` 是 key-path 版本的 map，等价于 Java
        // `recognized.stream().map(OCRTextRegion::text).toList()`。
        let texts = recognized.map(\.text)
        let translated: [String]
        var appliedFallback: ScreenshotTranslationFallback?
        do {
            translated = try await translator.translate(
                texts: texts,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage
            )
        } catch TextTranslationFailure.unableToIdentifyLanguage where sourceLanguage == nil {
            try Task.checkCancellation()
            guard fallback.sourceLanguage != fallback.targetLanguage,
                  ScreenshotTranslationFallback.supportedLanguageIdentifiers.contains(fallback.sourceLanguage),
                  ScreenshotTranslationFallback.supportedLanguageIdentifiers.contains(fallback.targetLanguage) else {
                throw AppFailure.invalidData("请在设置中选择不同的截图翻译备用语言")
            }
            // 只在自动语言识别失败时重试一次，复用同一批 OCR 文字和坐标。
            translated = try await translator.translate(
                texts: texts,
                sourceLanguage: fallback.sourceLanguage,
                targetLanguage: fallback.targetLanguage
            )
            appliedFallback = fallback
        }

        guard translated.count == recognized.count else {
            throw AppFailure.operationFailed("翻译结果数量与 OCR 区域不一致")
        }
        try Task.checkCancellation()

        // zip 把两个数组按相同下标组成元组序列；前面的 count 校验避免静默截断。
        let regions = zip(recognized, translated).map { pair in
            let (source, target) = pair
            return TranslatedTextRegion(
                sourceText: source.text,
                translatedText: target,
                normalizedRect: source.normalizedRect
            )
        }

        let rendered = try await renderer.render(image: image, regions: regions)
        return ImageTranslationResult(image: rendered, appliedFallback: appliedFallback)
    }
}
