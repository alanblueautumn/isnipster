import CoreGraphics
import Foundation
import iSnipsterCore

/// OCR 字符 DTO 不携带 Vision 的请求/观察对象；几何仍使用 CoreGraphics 的 CGRect。
public struct OCRCharacterRegion: Sendable, Equatable {
    public let text: String
    /// 单个字符的 Vision 标准化坐标：范围 0...1，原点在左下角。
    public let normalizedRect: CGRect

    /// false 表示 OCR 用等宽估算补位，不能用于局部敏感字符的精确遮盖。
    public let hasPreciseBounds: Bool

    public init(text: String, normalizedRect: CGRect, hasPreciseBounds: Bool = true) {
        self.text = text
        self.normalizedRect = normalizedRect
        self.hasPreciseBounds = hasPreciseBounds
    }
}

public struct OCRTextRegion: Sendable, Equatable {
    public let text: String
    public let confidence: Float
    /// Vision 标准化坐标：范围 0...1，原点在左下角。
    public let normalizedRect: CGRect
    public let characters: [OCRCharacterRegion]

    public init(
        text: String,
        confidence: Float,
        normalizedRect: CGRect,
        characters: [OCRCharacterRegion] = []
    ) {
        self.text = text
        self.confidence = confidence
        self.normalizedRect = normalizedRect
        self.characters = characters
    }
}

public protocol TextRecognizing: Sendable {
    func recognize(image: RasterImage, languages: [String]) async throws -> [OCRTextRegion]
}

