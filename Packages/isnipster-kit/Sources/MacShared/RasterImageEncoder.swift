import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import iSnipsterCore

/// 后台编码服务；编辑器和剪贴板无需互相依赖即可复用。
public actor RasterImageEncoder {
    public init() {}

    /// 把已有位图编码为 PNG Data；与 decode 不同，这里不从外部压缩数据重新探测格式。
    public func pngData(from image: RasterImage) throws -> Data {
        try encode(image.cgImage, type: .png)
    }

    /// 从 PNG 创建 TIFF 表示，供只接受 TIFF 的粘贴目标使用；不是替换历史中保存的原 PNG。
    public func tiffData(fromPNG data: Data) throws -> Data? {
        try Task.checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return try encode(image, type: .tiff)
    }

    /// 创建编码目标、添加一张图并 finalize；在前后检查取消，避免把废弃任务的输出交给调用者。
    private func encode(_ image: CGImage, type: UTType) throws -> Data {
        try Task.checkCancellation()
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, type.identifier as CFString, 1, nil
        ) else { throw AppFailure.operationFailed(AppText.text("图片编码失败")) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw AppFailure.operationFailed(AppText.text("图片编码失败"))
        }
        try Task.checkCancellation()
        return output as Data
    }

}
