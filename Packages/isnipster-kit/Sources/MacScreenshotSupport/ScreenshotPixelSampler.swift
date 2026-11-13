import MacShared
// 阅读路线
// 从 CGImage 的指定位置取颜色；先确定像素坐标，再用确定的位图格式读取通道。
// 原始图片可能不是统一的 RGBA 内存布局，不能随意把 dataProvider 的四个字节当颜色。
// 官方参考（CGContext 像素缓冲）：https://developer.apple.com/documentation/coregraphics/cgcontext

import ColorPickerFeature
import CoreGraphics
import Foundation

public struct ScreenshotPixelSample {
    public let image: CGImage
    public let color: SampledColor
    /// 左上原点，指向裁剪样本中实际采样的像素；靠近图片边缘时不一定在中心。
    public let pixelInSample: CGPoint
}

public enum ScreenshotPixelSampler {
    /// 先换算像素位置并取色，再裁出邻域；靠边时整体移动裁剪框，样本中的焦点不一定在正中央。
    public static func magnifiedSample(
        in image: CGImage,
        at point: CGPoint,
        displayedAt size: CGSize
    ) -> ScreenshotPixelSample? {
        guard let pixel = pixelPoint(in: image, at: point, displayedAt: size),
              let color = color(in: image, atPixel: pixel) else { return nil }
        let scale = max(CGFloat(image.width) / size.width, CGFloat(image.height) / size.height)
        let side = min(max(Int((20 * scale).rounded()), 1), min(image.width, image.height))
        let x = min(max(Int(pixel.x) - side / 2, 0), image.width - side)
        let y = min(max(Int(pixel.y) - side / 2, 0), image.height - side)
        guard let crop = image.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else { return nil }
        return ScreenshotPixelSample(
            image: crop,
            color: color,
            pixelInSample: CGPoint(x: pixel.x - CGFloat(x), y: pixel.y - CGFloat(y))
        )
    }

    public static func color(in image: CGImage, at point: CGPoint, displayedAt size: CGSize) -> SampledColor? {
        guard let pixel = pixelPoint(in: image, at: point, displayedAt: size) else { return nil }
        return color(in: image, atPixel: pixel)
    }

    /// 所有调用方传入左上原点的显示坐标，统一映射到冻结图片的物理像素。
    private static func pixelPoint(in image: CGImage, at point: CGPoint, displayedAt size: CGSize) -> CGPoint? {
        guard size.width > 0, size.height > 0, image.width > 0, image.height > 0 else { return nil }
        return CGPoint(
            x: min(max(floor(point.x * CGFloat(image.width) / size.width), 0), CGFloat(image.width - 1)),
            y: min(max(floor(point.y * CGFloat(image.height) / size.height), 0), CGFloat(image.height - 1))
        )
    }

    /// 将一个像素绘入已知 sRGB/RGBA 格式的缓冲，再还原非预乘颜色；避开源图未知的通道布局。
    private static func color(in image: CGImage, atPixel point: CGPoint) -> SampledColor? {
        guard let pixelImage = image.cropping(to: CGRect(origin: point, size: CGSize(width: 1, height: 1))),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var rgba = [UInt8](repeating: 0, count: 4)
        // 临时借用可写字节缓冲给 C API；指针只在闭包执行期间有效，不得存起来供异步回调使用。
        let rendered = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let address = bytes.baseAddress,
                  let context = CGContext(
                    data: address, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            // 关闭位图缩放插值，保留像素块边界；适合取色放大，普通照片缩小则可能需要其他策略。
            context.interpolationQuality = .none
            context.draw(pixelImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard rendered else { return nil }
        let alpha = Double(rgba[3]) / 255
        // 缓冲使用预乘 alpha：RGB 已乘透明度，因此除以 alpha 字节还原通道；透明度为 0 时用 1 避免除零。
        let divisor = Double(max(rgba[3], 1))
        return SampledColor(
            red: Double(rgba[0]) / divisor,
            green: Double(rgba[1]) / divisor,
            blue: Double(rgba[2]) / divisor,
            alpha: alpha
        )
    }
}
