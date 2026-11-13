import MacShared
// 阅读路线
// 每个 OCR 框扩出边距、取平均背景色、覆盖原文，再二分字号并用 CoreText 绘译文。
// CIContext 计算滤镜结果，CGContext 合成最终像素；两者职责不同，均不等于界面 View。
// 官方参考（Core Image 滤镜渲染）：https://developer.apple.com/documentation/coreimage/cicontext

import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageTranslationFeature
import iSnipsterCore

// CoreText 类似脱离 DOM 的文字排版引擎；先测量字号，再将译文写进位图区域。
// 这里的圆角、内边距和颜色作用于导出图片，不是窗口 CSS；调整它们会直接改变最终图片。

/// 将译文直接合成到原图，而不是返回单独的翻译弹窗。
///
/// 用扩大采样区域的平均色覆盖原文，再选择深/浅色绘制译文。
/// 这是色块覆盖，不是背景修复；纹理或渐变背景可能留下可见补丁。
///
/// 渲染器是 actor：CIContext 可以复用，但每次 render 都创建独立 CGContext 输出缓冲区。
/// 整个过程只操作内存中的像素，没有文件 URL，也没有网络请求。
public actor CoreGraphicsTranslationRenderer: ImageTranslationRendering {
    private let ciContext = CIContext(options: [.cacheIntermediates: false])
    private let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    public init() {}

    public func render(
        image: RasterImage,
        regions: [TranslatedTextRegion]
    ) async throws -> RasterImage {
        let width = image.cgImage.width
        let height = image.cgImage.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: outputColorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AppFailure.operationFailed(AppText.text("无法创建图片翻译渲染缓冲区"))
        }

        let imageBounds = CGRect(x: 0, y: 0, width: width, height: height)
        context.draw(image.cgImage, in: imageBounds)
        let ciImage = CIImage(cgImage: image.cgImage)

        // 每个 OCR 区域执行三步：坐标换算 -> 背景覆盖 -> 自适应字号绘制译文。
        for region in regions {
            // 用户按 Esc 关闭截图时及时停止后续区域渲染，避免后台继续占用大图缓冲。
            try Task.checkCancellation()
            let rect = pixelRect(from: region.normalizedRect, width: width, height: height)
                .insetBy(dx: -4, dy: -3)
                .intersection(imageBounds)
            guard rect.width >= 4, rect.height >= 4 else { continue }

            // 不直接用文字框内部取色：里面包含深色/浅色字形，会把补丁颜色带偏。
            // 扩大采样范围后，周围真实背景占比更高；最终仍只覆盖原 OCR 矩形。
            let sampleRect = rect.insetBy(
                dx: -max(4, rect.width * 0.10),
                dy: -max(4, rect.height * 0.35)
            ).intersection(imageBounds)
            let background = averageColor(of: ciImage, in: sampleRect)
            // 覆盖层设为不透明，避免原文字形透过背景色。
            context.setFillColor(background.copy(alpha: 1) ?? background)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
            context.fillPath()

            let luminance = 0.2126 * background.componentsValue(at: 0)
                + 0.7152 * background.componentsValue(at: 1)
                + 0.0722 * background.componentsValue(at: 2)
            let foreground = luminance > 0.55
                ? CGColor(gray: 0.05, alpha: 1)
                : CGColor(gray: 0.98, alpha: 1)
            drawText(region.translatedText, in: rect.insetBy(dx: 3, dy: 2), color: foreground, context: context)
        }

        guard let output = context.makeImage() else {
            throw AppFailure.operationFailed(AppText.text("无法生成图片翻译结果"))
        }
        return RasterImage(cgImage: output)
    }

    private func pixelRect(from normalized: CGRect, width: Int, height: Int) -> CGRect {
        // Vision 与 Core Graphics 都使用左下原点，因此这里无需再次翻转 Y 轴。
        CGRect(
            x: normalized.minX * CGFloat(width),
            y: normalized.minY * CGFloat(height),
            width: normalized.width * CGFloat(width),
            height: normalized.height * CGFloat(height)
        ).integral
    }

    /// areaAverage 把采样区域归约成 1×1 像素，读取这一像素作为覆盖背景色。
    private func averageColor(of image: CIImage, in rect: CGRect) -> CGColor {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = rect

        guard let output = filter.outputImage else {
            return CGColor(gray: 0.92, alpha: 1)
        }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(
            output,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: outputColorSpace
        )
        return CGColor(
            colorSpace: outputColorSpace,
            components: pixel.map { CGFloat($0) / 255 }
        ) ?? CGColor(gray: 0.92, alpha: 1)
    }

    private func drawText(_ text: String, in rect: CGRect, color: CGColor, context: CGContext) {
        let fontSize = fittingFontSize(for: text, in: rect)
        // 创建 CoreText 字体供位图排版使用；SwiftUI Font、AppKit NSFont 与 CTFont 属于不同 API 层。
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, fontSize, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
            ]
        )
        // CoreText 根据带字体/颜色的文本创建排版器；后续用指定宽高求换行并生成绘制 frame。
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            // Core Foundation 的范围用整数位置/长度；文字排版处通常对应 UTF-16，不要直接用 Swift Character 数替换。
            CFRange(location: 0, length: attributed.length),
            path,
            nil
        )
        // 把排版后的字形绘入当前 CGContext；位置由 CoreText frame 的路径和上下文坐标变换共同决定。
        CTFrameDraw(frame, context)
    }

    /// 类似文本 fit-to-box：字号越大通常越占高度，用二分缩小可行范围，避免逐号试探。
    private func fittingFontSize(for text: String, in rect: CGRect) -> CGFloat {
        let upperBound = min(max(rect.height * 0.72, 11), 34)
        var low: CGFloat = 8
        var high = upperBound

        // 用固定 7 轮二分搜索找最大可容纳字号，复杂度稳定，不会在主线程测量 UI。
        for _ in 0..<7 {
            let candidate = (low + high) / 2
            let font = CTFontCreateWithName("Helvetica Neue" as CFString, candidate, nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
            )
            let framesetter = CTFramesetterCreateWithAttributedString(attributed)
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(
                framesetter,
                CFRange(location: 0, length: attributed.length),
                nil,
                CGSize(width: rect.width, height: CGFloat.greatestFiniteMagnitude),
                nil
            )
            if measured.height <= rect.height {
                low = candidate
            } else {
                high = candidate
            }
        }
        return low
    }
}

private extension CGColor {
    func componentsValue(at index: Int) -> CGFloat {
        guard let components else { return 0.5 }
        if numberOfComponents == 2 {
            return components[0]
        }
        return components[min(index, numberOfComponents - 1)]
    }
}
