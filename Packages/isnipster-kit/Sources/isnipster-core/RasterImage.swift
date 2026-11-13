// 阅读路线
// CGImage 承载像素，RasterImage 补上身份与创建时间，让截图、编辑、OCR 使用同一数据类型。
// 结构体赋值遵循值语义，但内部 CGImage 是共享引用；@unchecked Sendable 的安全性要由作者保证。
// 官方参考（Sendable 并发传递契约）：https://docs.swift.org/latest/documentation/swift/sendable/

import CoreGraphics
import Foundation

/// Feature 之间传递的不可变位图。
///
/// CGImage 创建完成后，其像素内容不可变，可以安全地作为值在 actor 之间传递。
/// Core Graphics 尚未为所有引用类型完整标注 Sendable，因此在这一处集中承担
/// unchecked 边界，避免在业务代码里四处使用非隔离对象。
///
/// Java 对照：struct 是值类型，赋值时具有值语义；这里像一个不可变 record。
/// `@unchecked Sendable` 表示作者向编译器担保它可跨并发域传递，必须谨慎集中使用。
public struct RasterImage: @unchecked Sendable, Identifiable {
    // Identifiable 要求稳定 id；重新包装同一个 CGImage 默认也会生成新 UUID，像素相同不等于记录相同。
    public let id: UUID
    public let cgImage: CGImage
    public let createdAt: Date

    public init(id: UUID = UUID(), cgImage: CGImage, createdAt: Date = .now) {
        self.id = id
        self.cgImage = cgImage
        self.createdAt = createdAt
    }

    // 单表达式计算属性可以省略 return，不额外存储字段。
    public var pixelWidth: Int { cgImage.width }
    public var pixelHeight: Int { cgImage.height }

    // bytesPerRow 包含每行对齐占用；乘高度估算解码缓冲，不能用 PNG 文件大小估算内存。
    public var estimatedDecodedBytes: Int {
        // 每行内存步长可能包含对齐填充；用步长乘高度估算缓冲，比直接按宽×高×通道数更贴近实际。
        cgImage.bytesPerRow * cgImage.height
    }
}
