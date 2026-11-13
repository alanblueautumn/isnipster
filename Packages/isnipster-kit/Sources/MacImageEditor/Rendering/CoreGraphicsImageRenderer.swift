import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 原图 → 新位图 CGContext → 顺序重放命令 → CGImage；预览与导出使用同一像素坐标模型。
// CoreText 绘字使用左下原点，编辑命令用左上原点；几何翻转与字形绘制需要分别处理。
// 官方参考（Core Graphics 位图绘制）：https://developer.apple.com/documentation/coregraphics/cgcontext

import CoreText
import Foundation
import ImageEditorFeature
import iSnipsterCore

// CGContext 类似 HTML CanvasRenderingContext2D：设置画笔状态、添加路径、绘制到位图。
// 绘制顺序就是覆盖顺序；saveGState/restoreGState 类似 canvas.save/restore，防止坐标变换污染后续命令。

/// 把矢量编辑操作展平为最终位图。渲染器不持有历史，调用结束后中间缓冲即可释放。
///
/// Java 对照：可以把它理解成无状态的 ExportService。传入不可变 Snapshot，按命令顺序
/// 重放到一块新的 bitmap buffer，最后返回不可变 RasterImage；原图从不被修改。
public actor CoreGraphicsImageRenderer: ImageRendering {
    public init() {}

    /// 输出缓冲与原图分离，先画基底再重放标注；因此导出不会破坏撤销历史共享的 CGImage。
    public func render(document: ImageDocumentSnapshot) async throws -> RasterImage {
        let source = document.original.cgImage
        guard let context = Self.makeBitmapContext(width: source.width, height: source.height) else {
            throw AppFailure.operationFailed(AppText.text("无法创建图片渲染缓冲区"))
        }

        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))

        // 编辑器保存的是命令列表，导出时按顺序重放；后面的操作自然覆盖前面的操作。
        let removedRedactionIDs = ImageEditOperation.removedRedactionIDs(in: document.operations)
        for operation in document.operations {
            try draw(
                operation: operation,
                in: context,
                source: source,
                removedRedactionIDs: removedRedactionIDs
            )
        }

        guard let output = context.makeImage() else {
            throw AppFailure.operationFailed(AppText.text("无法生成编辑后的图片"))
        }
        return RasterImage(cgImage: output)
    }

    /// 把单个命令转换为 Core Graphics 绘制。`.batch` 递归展开子命令，
    /// 让智能打码一次提交的多个不透明色块在导出时按原顺序重放。
    private func draw(
        operation: ImageEditOperation,
        in context: CGContext,
        source: CGImage,
        removedRedactionIDs: Set<UUID>
    ) throws {
        switch operation {
        case let .shape(_, rect, style, isFilled, shape):
            drawFlipped(in: context, height: CGFloat(source.height)) { ctx in
                // 形状在领域命令中已经确定。导出层只负责把同一个命令转换为
                // Core Graphics 路径，保证最终图片与 SwiftUI 画布预览一致。
                let path: CGPath = switch shape {
                case .rectangle:
                    CGPath(rect: rect, transform: nil)
                case .ellipse:
                    CGPath(ellipseIn: rect, transform: nil)
                }
                ctx.setStrokeColor(style.color.cgColor)
                ctx.setFillColor(style.color.cgColor)
                ctx.setLineWidth(style.width)
                ctx.addPath(path)
                if isFilled {
                    ctx.drawPath(using: .fillStroke)
                } else {
                    ctx.strokePath()
                }
            }
        case let .arrow(_, start, end, style, mode):
            drawArrow(
                in: context,
                height: CGFloat(source.height),
                start: start,
                end: end,
                style: style,
                mode: mode
            )
        case let .freehand(_, points, style):
            drawFreehand(in: context, height: CGFloat(source.height), points: points, style: style)
        case let .text(_, value, rect, color, fontSize):
            drawText(value, in: rect, color: color, fontSize: fontSize, context: context, height: CGFloat(source.height))
        case let .redaction(id, rect, color):
            guard !removedRedactionIDs.contains(id) else { return }
            // 色块是纯 Core Graphics fill，不读取和复制整张当前画面。
            // 每个色块只需一次矩形填充；不为每个区域创建模糊滤镜和整图中间缓冲。
            drawFlipped(in: context, height: CGFloat(source.height)) { ctx in
                ctx.setFillColor(color.cgColor)
                ctx.fill(rect)
            }
        case .removeRedaction:
            // 取消命令已经汇总进 removedRedactionIDs，本身不产生任何像素。
            break
        case let .step(_, number, center, diameter, color):
            drawStep(
                number: number,
                center: center,
                diameter: diameter,
                color: color,
                context: context,
                imageHeight: CGFloat(source.height)
            )
        case let .batch(_, operations):
            for sub in operations {
                try draw(
                    operation: sub,
                    in: context,
                    source: source,
                    removedRedactionIDs: removedRedactionIDs
                )
            }
        }
    }

    private nonisolated func drawArrow(
        in context: CGContext,
        height: CGFloat,
        start: CGPoint,
        end: CGPoint,
        style: StrokeStyle,
        mode: ArrowMode
    ) {
        drawFlipped(in: context, height: height) { ctx in
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setFillColor(style.color.cgColor)

            switch mode {
            case .line:
                ctx.setLineWidth(style.width)
                ctx.setLineCap(.round)
                ctx.move(to: start)
                ctx.addLine(to: end)
                ctx.strokePath()

            case .arrow:
                // 与 SwiftUI 预览共用 ArrowGeometry，复制出来的图片不会出现另一种箭头比例。
                let points = ArrowGeometry.polygon(from: start, to: end, width: style.width)
                guard let first = points.first else { return }
                ctx.move(to: first)
                points.dropFirst().forEach { ctx.addLine(to: $0) }
                ctx.closePath()
                ctx.fillPath()
            }
        }
    }

    private nonisolated func drawFreehand(
        in context: CGContext,
        height: CGFloat,
        points: [CGPoint],
        style: StrokeStyle
    ) {
        guard let first = points.first else { return }
        drawFlipped(in: context, height: height) { ctx in
            ctx.setStrokeColor(style.color.cgColor)
            ctx.setLineWidth(style.width)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: first)
            points.dropFirst().forEach(ctx.addLine(to:))
            ctx.strokePath()
        }
    }

    private nonisolated func drawText(
        _ value: String,
        in rect: CGRect,
        color: RGBAColor,
        fontSize: CGFloat,
        context: CGContext,
        height: CGFloat
    ) {
        let coreGraphicsRect = CGRect(
            x: rect.minX,
            y: height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        // 创建 CoreText 字体供位图排版使用；SwiftUI Font、AppKit NSFont 与 CTFont 属于不同 API 层。
        let font = CTFontCreateWithName("Helvetica Neue Medium" as CFString, fontSize, nil)
        let attributed = NSAttributedString(
            string: value,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
            ]
        )
        // CoreText 根据带字体/颜色的文本创建排版器；后续用指定宽高求换行并生成绘制 frame。
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            // Core Foundation 的范围用整数位置/长度；文字排版处通常对应 UTF-16，不要直接用 Swift Character 数替换。
            CFRange(location: 0, length: attributed.length),
            CGPath(rect: coreGraphicsRect, transform: nil),
            nil
        )
        // 把排版后的字形绘入当前 CGContext；位置由 CoreText frame 的路径和上下文坐标变换共同决定。
        CTFrameDraw(frame, context)
    }

    private nonisolated func drawStep(
        number: Int,
        center: CGPoint,
        diameter: CGFloat,
        color: RGBAColor,
        context: CGContext,
        imageHeight: CGFloat
    ) {
        let imageRect = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        drawFlipped(in: context, height: imageHeight) { ctx in
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: imageRect)
            ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.95))
            ctx.setLineWidth(max(2, diameter * 0.06))
            ctx.strokeEllipse(in: imageRect.insetBy(dx: 1, dy: 1))
        }

        // 圆形使用左上原点的编辑坐标；CoreText 使用左下原点，因此只转换中心 Y。
        let text = "\(number)"
        let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, diameter * 0.52, nil)
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, [.useOpticalBounds])
        context.textPosition = CGPoint(
            x: center.x - bounds.width / 2 - bounds.minX,
            y: imageHeight - center.y - bounds.height / 2 - bounds.minY
        )
        CTLineDraw(line, context)
    }

    private nonisolated func drawFlipped(
        in context: CGContext,
        height: CGFloat,
        body: (CGContext) -> Void
    ) {
        // 编辑模型使用左上原点，Core Graphics 默认左下原点。保存矩阵后做一次 Y 翻转，
        // 执行绘制闭包，再恢复，避免坐标转换散落在每种工具里。
        context.saveGState()
        context.translateBy(x: 0, y: height)
        // 修改上下文的坐标变换矩阵；后续绘制使用变换后的坐标，不会直接改写领域模型中的点。
        context.scaleBy(x: 1, y: -1)
        body(context)
        context.restoreGState()
    }

    private nonisolated static func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        // data:nil 让 Core Graphics 自己分配像素缓冲；bytesPerRow:0 由系统选择合适步长。
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }
}

private extension RGBAColor {
    var cgColor: CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [red, green, blue, alpha]
        )!
    }
}
