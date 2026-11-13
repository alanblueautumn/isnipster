// 阅读路线
// OCR 输出字符/文本区域，翻译输出与原区域绑定，Renderer 根据归一化矩形回写位图。
// 这些 DTO 不持有 Vision 会话或窗口；Sendable 让它们可跨识别 actor 与 UI 隔离域传递。
// 官方参考（Swift 结构体与类）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/

import CoreGraphics
import Foundation
import iSnipsterCore

/// 将译文与原始 OCR 区域重新绑定后的图片重绘输入。
public struct TranslatedTextRegion: Sendable, Equatable {
    public let sourceText: String
    public let translatedText: String
    public let normalizedRect: CGRect

    public init(sourceText: String, translatedText: String, normalizedRect: CGRect) {
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.normalizedRect = normalizedRect
    }
}

/// 三个协议分别对应 OCR、翻译、图像重绘三个端口，类似 Java 六边形架构的接口。
/// 实现放在 MacPlatform，Pipeline 只面向这些抽象编程。
/// 抽象把翻译文字合成回图片的渲染能力。
public protocol ImageTranslationRendering: Sendable {
    func render(image: RasterImage, regions: [TranslatedTextRegion]) async throws -> RasterImage
}
