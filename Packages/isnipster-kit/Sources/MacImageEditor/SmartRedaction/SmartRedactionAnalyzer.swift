import MacShared
import MacScreenshotSupport
import MacTranslation
import RecognitionFeature
// 阅读路线
// OCR → 文本规则 → 相邻数字拼接 → 标签布局 → 去重 → 编辑框，是自动打码的数据流。
// Analyzer 返回候选区域，不直接改文档；最终色块以 batch 命令提交，允许整体撤销。
// 官方参考（Vision 文字与区域）：https://developer.apple.com/documentation/vision/vnrecognizedtext

import CoreGraphics
import Foundation
import ImageEditorFeature
import ImageTranslationFeature
import iSnipsterCore

struct SmartRedactionRegion: Sendable {
    let normalizedRect: CGRect

    /// 文本余量随字高变化，不随整行宽度膨胀；仅在输出编辑框时翻转 Y。
    func editorRect(imageSize: CGSize) -> CGRect {
        let rect = RedactionGeometry.pixels(normalizedRect, imageSize: imageSize)
        let padding = rect.height * 0.06
        return CGRect(x: rect.minX - padding, y: imageSize.height - rect.maxY - padding,
                      width: rect.width + padding * 2, height: rect.height + padding * 2)
            .intersection(CGRect(origin: .zero, size: imageSize))
    }
}

/// 独立 actor 编排敏感文本规则、字符定位及字段关联，主线程只提交编辑命令。
actor SmartRedactionAnalyzer {
    private let recognizer: any TextRecognizing

    init(recognizer: any TextRecognizing) {
        self.recognizer = recognizer
    }

    func analyze(_ image: RasterImage) async throws -> [SmartRedactionRegion] {
        try Task.checkCancellation()
        let texts = try await recognizer.recognize(image: image, languages: ["zh-Hans", "en-US"])
        try Task.checkCancellation()
        let size = CGSize(width: CGFloat(image.pixelWidth), height: CGFloat(image.pixelHeight))
        // enumerated 同时给出原数组下标和值，类似 Java 索引循环；后续标签匹配用此下标找回原 OCR 区域。
        let layout = texts.enumerated().map { index, region in
            RedactionTextLayout(index: index, text: region.text,
                                rect: RedactionGeometry.pixels(region.normalizedRect, imageSize: size),
                                confidence: region.confidence)
        }

        var rects = texts.filter { $0.confidence >= 0.65 }.flatMap { text in
            RedactionTextLocator.rects(for: SensitiveTextDetector.ranges(in: text.text), in: text)
        }
        rects += RedactionTextLocator.joinedNumberRects(texts: texts, layout: layout)
        let selected = SensitiveFieldLayoutMatcher.matchingIndices(in: layout)
        rects += selected.sorted().flatMap { index in
            let text = texts[index]
            return RedactionTextLocator.rects(
                for: [NSRange(text.text.startIndex..<text.text.endIndex, in: text.text)], in: text
            )
        }
        try Task.checkCancellation()
        return RedactionGeometry.uniqueOuterRects(rects).map { SmartRedactionRegion(normalizedRect: $0) }
    }
}
