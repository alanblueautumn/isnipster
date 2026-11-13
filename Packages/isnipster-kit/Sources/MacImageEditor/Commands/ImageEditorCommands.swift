import MacShared
import MacScreenshotSupport
import MacTranslation
import RecognitionFeature
// 阅读路线
// 将文档快照送去渲染、OCR、翻译或打码；打码直接提交文档，其余结果交还调用者。
// 这是编辑器的应用服务层；异步工作前固定输入，恢复后检查取消，避免已关闭会话继续提交。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import AppKit
import CaptureFeature
import ColorPickerFeature
import CoreImage
import ImageEditorFeature
import ImageTranslationFeature
import Observation
import iSnipsterCore
import SwiftUI
@preconcurrency import Translation

/// 编辑器的异步用例。类似 Vue composable / Java ApplicationService：
/// 负责 OCR、智能打码和翻译，不创建窗口、不决定控件样式。
/// 窗口控制器拥有 Task 的取消权；本服务在产生副作用前响应取消。
@MainActor
final class ImageEditorCommands {
    private let renderer: any ImageRendering
    private let recognizer: any TextRecognizing
    private let smartRedactionAnalyzer: SmartRedactionAnalyzer
    private let translationPipeline: ImageTranslationPipeline

    init(renderer: any ImageRendering, recognizer: any TextRecognizing,
         translationPipeline: ImageTranslationPipeline) {
        self.renderer = renderer
        self.recognizer = recognizer
        self.smartRedactionAnalyzer = SmartRedactionAnalyzer(recognizer: recognizer)
        self.translationPipeline = translationPipeline
    }

    /// OCR 返回自然阅读顺序的文字区域；展示和单区复制由编辑会话处理。
    func recognize(document: ImageDocument) async throws -> [OCRTextRegion] {
        try Task.checkCancellation()
        let image = try await renderer.render(document: document.snapshot())
        try Task.checkCancellation()
        let regions = try await recognizer.recognize(
            image: image,
            languages: ["zh-Hans", "en-US"]
        )
        guard !regions.isEmpty else {
            throw AppFailure.invalidData(AppText.text("所选区域没有识别到文字"))
        }

        // 先按严格次序建立行，再按行内横坐标排序。不能在比较器里用两两 Y 差
        // 判断“同一行”，这种近似关系不传递，会出现 A < B < C < A。
        let topToBottom = regions.enumerated().sorted { lhs, rhs in
            let left = lhs.element.normalizedRect
            let right = rhs.element.normalizedRect
            if left.midY != right.midY { return left.midY > right.midY }
            if left.minX != right.minX { return left.minX < right.minX }
            return lhs.offset < rhs.offset
        }
        var rows: [[(offset: Int, element: OCRTextRegion)]] = []
        for region in topToBottom {
            if let anchor = rows.last?.first?.element.normalizedRect,
               abs(anchor.midY - region.element.normalizedRect.midY)
                    <= min(anchor.height, region.element.normalizedRect.height) * 0.5 {
                rows[rows.count - 1].append(region)
            } else {
                rows.append([region])
            }
        }
        // 先建立近似同一行的分组，再按 X 排序；最后 flatMap 展平，形成 OCR 选择与复制的阅读顺序。
        let ordered = rows.flatMap { row in
            row.sorted { lhs, rhs in
                let leftX = lhs.element.normalizedRect.minX
                let rightX = rhs.element.normalizedRect.minX
                return leftX == rightX ? lhs.offset < rhs.offset : leftX < rightX
            }.map(\.element)
        }
        try Task.checkCancellation()
        return ordered
    }

    /// 智能打码的用例边界：分析算法交给独立管道，这里只读取基底图并一次性提交撤销命令。
    func smartRedaction(document: ImageDocument) async throws -> Int {
        // 智能打码识别基底原图，避免用户已有遮挡影响候选识别；结果恢复时再追加到当前操作列表。
        let sourceImage = document.original
        // detached 不继承 MainActor，也不自动继承父任务的取消；这里只捕获可发送的 RasterImage 执行同步缩图。
        // 等待 .value 后仍需由外层检查取消，不能把 detached 当成自动管理生命周期的子任务组。
        let recognitionImage = await Task.detached(priority: .userInitiated) {
            Self.downsampleForTextRecognition(sourceImage)
        }.value
        let regions = try await smartRedactionAnalyzer.analyze(recognitionImage)
        try Task.checkCancellation()
        guard !regions.isEmpty else {
            throw AppFailure.invalidData(AppText.text("没有检测到需要遮盖的敏感信息"))
        }

        let imageSize = document.imageSize
        let color = document.strokeColor(for: .redaction)
        let operations = regions.map {
            ImageEditOperation.redaction(
                id: UUID(), rect: $0.editorRect(imageSize: imageSize), color: color
            )
        }
        // 保留一次撤销全部自动结果、单击取消单个色块和手动补框的原有交互。
        document.commit(.batch(id: UUID(), operations: operations))
        return operations.count
    }

    /// OCR 只关心文字和归一化位置，不需要把 5K/Retina 截图按原尺寸交给 Vision。
    ///
    /// Java 对照：类似先生成一张最长边 2560px 的临时 BufferedImage 做识别；识别框是
    /// 0...1 的比例坐标，最终可按原始 imageSize 映射色块；缩小仍可能影响小字的识别和定位精度。
    private nonisolated static func downsampleForTextRecognition(_ image: RasterImage) -> RasterImage {
        // 写在 nonisolated 方法内部，明确这个阈值只属于后台缩放算法，不依赖 MainActor 状态。
        let maximumDimension = 2_560
        let source = image.cgImage
        let longestSide = max(source.width, source.height)
        guard longestSide > maximumDimension else { return image }

        let scale = CGFloat(maximumDimension) / CGFloat(longestSide)
        let targetWidth = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let targetHeight = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: targetWidth,
                height: targetHeight,
                bitsPerComponent: 8,
                bytesPerRow: targetWidth * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            // 缩放失败只影响性能，不应该阻断打码功能，直接回退原图识别。
            return image
        }

        context.interpolationQuality = .medium
        context.draw(source, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        guard let downsampled = context.makeImage() else { return image }
        return RasterImage(cgImage: downsampled, createdAt: image.createdAt)
    }

    /// 翻译前先把当前矢量操作展平，再交给图片内翻译管道；返回的新图继续留在同一编辑器。
    func translate(
        document: ImageDocument,
        sourceLanguage: String?,
        targetLanguage: String,
        fallback: ScreenshotTranslationFallback
    ) async throws -> ImageTranslationResult {
        let visibleImage = try await renderer.render(document: document.snapshot())
        // 翻译重绘仍使用全分辨率原图；只有 OCR 使用最长边 2560px 的临时图。
        // Vision 返回比例坐标，可映射回原尺寸；导出分辨率保留，但 OCR 精度仍受缩图影响。
        let recognitionImage = await Task.detached(priority: .userInitiated) {
            Self.downsampleForTextRecognition(visibleImage)
        }.value
        return try await translationPipeline.translate(
            image: visibleImage,
            recognitionImage: recognitionImage,
            recognitionLanguages: Array(Set(["zh-Hans", "en-US", fallback.sourceLanguage, sourceLanguage].compactMap { $0 })).sorted(),
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage,
            fallback: fallback
        )
    }

}
