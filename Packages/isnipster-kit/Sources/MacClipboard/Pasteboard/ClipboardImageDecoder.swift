import MacShared
import MacPreferences
// 阅读路线
// 先读图片尺寸和预算，再按需要转 PNG；写回剪贴板时可额外准备 TIFF 表示。
// 独立 actor 承担同步编码工作；图片压缩大小与解码像素内存不是同一个限制。
// 官方参考（Image I/O 编解码）：https://developer.apple.com/documentation/imageio

import Foundation
import CoreGraphics
import ImageIO
import ClipboardFeature
import UniformTypeIdentifiers
import iSnipsterCore

/// 后台图片适配器。actor 类似串行 Worker；它与 MainActor 分离，避免 TIFF 转 PNG 阻塞 UI。
/// ImageIO 先读取元数据，再分配像素；压缩文件很小也可能解码成很大的图片。
actor ClipboardImageDecoder {
    /// 约 128 MB 的 RGBA 像素上限。编码过程还会产生临时缓冲，因此同时限制原始数据大小。
    private let encoder = RasterImageEncoder()
    private let maximumPixels = 32 * 1_024 * 1_024

    /// 三道边界：原始字节数 → 元数据像素数 → PNG 输出字节数。
    /// 用除法比较像素预算，避免恶意宽高相乘时 Int 溢出；不缩小合法图片，保留原分辨率。
    func decode(_ data: Data, maxBytes: Int) -> ClipboardContent? {
        guard !Task.isCancelled, data.count <= maxBytes,
              // ImageIO 从编码字节创建图片源；读取元数据不等于已经完整解码所有像素。
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false
              ] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumPixels / height else { return nil }

        // PNG 已是存储格式，只读尺寸，不重复解码和编码。
        if CGImageSourceGetType(source) == UTType.png.identifier as CFString {
            return .imagePNG(data, pixelWidth: width, pixelHeight: height)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              !Task.isCancelled else { return nil }
        let output = NSMutableData()
        // ImageIO 的 destination 是编码目标；添加图片后必须 Finalize 才得到完整 PNG/TIFF 数据。
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        // 提交图片编码并检查成功标志；不能把尚未 finalize 的缓冲当作完整文件发布。
        guard CGImageDestinationFinalize(destination), output.length <= maxBytes,
              !Task.isCancelled else { return nil }
        return .imagePNG(output as Data, pixelWidth: width, pixelHeight: height)
    }
    func tiffData(fromPNG data: Data) async throws -> Data? {
        try await encoder.tiffData(fromPNG: data)
    }
}
