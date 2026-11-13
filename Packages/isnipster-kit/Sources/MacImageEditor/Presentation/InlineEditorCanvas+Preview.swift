import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 先重放已提交命令，再绘制当前拖动草稿；像素坐标经 displayRect 映射到当前 View。
// SwiftUI GraphicsContext 与导出的 CGContext 是两个绘图 API，但必须读取同一份命令数据。
// 官方参考（SwiftUI Canvas）：https://developer.apple.com/documentation/swiftui/canvas

import AppKit
import CoreText
import ImageEditorFeature
import SwiftUI

extension InlineEditorCanvas {
    /// SwiftUI Canvas 类似 HTML canvas：按顺序重放命令，预览读取与导出相同的领域数据。
    /// displayRect 只影响显示映射，不把缩放结果写回 Document。
    func drawOperations(
        _ operations: [ImageEditOperation],
        context: inout GraphicsContext,
        displayRect: CGRect
    ) {
        let removedRedactionIDs = ImageEditOperation.removedRedactionIDs(in: operations)
        operations.forEach {
            draw(
                operation: $0,
                context: &context,
                displayRect: displayRect,
                removedRedactionIDs: removedRedactionIDs
            )
        }
    }

    /// 用当前拖动状态绘制临时标注，既不修改原图，也不写入文档命令列表。
    func drawDraft(context: inout GraphicsContext, displayRect: CGRect) {
        guard let start = session.dragStart, let end = session.draftPoints.last else { return }
        let id = UUID()
        let rect = CGRect(
            x: start.x,
            y: start.y,
            width: end.x - start.x,
            height: end.y - start.y
        ).standardized
        let operation: ImageEditOperation

        switch session.document.selectedTool {
        case .rectangle:
            operation = .shape(
                id: id,
                rect: rect,
                style: session.document.strokeStyle,
                isFilled: session.document.shapeIsFilled,
                shape: session.document.annotationShape
            )
        case .arrow:
            operation = .arrow(
                id: id,
                start: start,
                end: end,
                style: session.document.strokeStyle,
                mode: session.document.arrowMode
            )
        case .pen:
            operation = .freehand(id: id, points: session.draftPoints, style: session.document.strokeStyle)
        case .redaction:
            // 单击只负责取消已有色块，不绘制一个几乎不可见的新色块。
            guard rect.width >= 2, rect.height >= 2 else { return }
            operation = .redaction(id: id, rect: rect, color: session.document.strokeStyle.color)
        case .text:
            return
        case .step:
            operation = .step(
                id: id,
                number: session.document.nextStepNumber,
                center: end,
                diameter: max(44, session.document.strokeStyle.width * 11),
                color: session.document.strokeStyle.color
            )
        case .colorPicker:
            return
        }
        draw(
            operation: operation,
            context: &context,
            displayRect: displayRect,
            removedRedactionIDs: []
        )
    }

    private func draw(
        operation: ImageEditOperation,
        context: inout GraphicsContext,
        displayRect: CGRect,
        removedRedactionIDs: Set<UUID>
    ) {
        let imageSize = session.document.imageSize
        let scaleX = displayRect.width / imageSize.width
        let scaleY = displayRect.height / imageSize.height
        let strokeScale = min(scaleX, scaleY)

        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(
                x: displayRect.minX + value.x * scaleX,
                y: displayRect.minY + value.y * scaleY
            )
        }
        func rect(_ value: CGRect) -> CGRect {
            CGRect(
                x: point(value.origin).x,
                y: point(value.origin).y,
                width: value.width * scaleX,
                height: value.height * scaleY
            )
        }

        switch operation {
        case let .shape(_, value, style, isFilled, shape):
            // SwiftUI 预览和 Core Graphics 导出都根据 AnnotationShape 分支，
            // 而不是用很大的圆角半径近似椭圆。
            let path: Path = switch shape {
            case .rectangle:
                Path(rect(value))
            case .ellipse:
                Path(ellipseIn: rect(value))
            }
            if isFilled {
                context.fill(path, with: .color(style.color.swiftUIColor))
            }
            context.stroke(
                path,
                with: .color(style.color.swiftUIColor),
                lineWidth: style.width * strokeScale
            )
        case let .arrow(_, start, end, style, mode):
            drawArrow(
                from: point(start),
                to: point(end),
                color: style.color.swiftUIColor,
                width: style.width * strokeScale,
                mode: mode,
                context: &context
            )
        case let .freehand(_, points, style):
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: point(first))
            points.dropFirst().forEach { path.addLine(to: point($0)) }
            context.stroke(
                path,
                with: .color(style.color.swiftUIColor),
                style: SwiftUI.StrokeStyle(
                    lineWidth: style.width * strokeScale,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        case let .text(id, value, valueRect, color, fontSize):
            var effectiveRect = valueRect
            if let move = committedTextMove, move.id == id {
                effectiveRect.origin = move.currentOrigin
            }
            let target = rect(effectiveRect)
            drawWrappedText(
                value,
                in: target,
                color: color,
                fontSize: fontSize * strokeScale,
                context: &context
            )
        case let .redaction(id, value, color):
            guard !removedRedactionIDs.contains(id) else { return }
            let target = rect(value)
            // 不透明色块不采样背景，也不需要创建离屏滤镜图层；一次 fill 即可完成预览。
            // 这既消除不同背景产生的颜色差异，也让多个敏感区域几乎没有额外渲染成本。
            context.fill(Path(target), with: .color(color.swiftUIColor))
        case .removeRedaction:
            // 删除命令只改变活动色块集合，不直接绘制内容。
            return
        case let .step(_, number, center, diameter, color):
            let displayCenter = point(center)
            let displayDiameter = diameter * strokeScale
            let markerRect = CGRect(
                x: displayCenter.x - displayDiameter / 2,
                y: displayCenter.y - displayDiameter / 2,
                width: displayDiameter,
                height: displayDiameter
            )
            context.fill(Path(ellipseIn: markerRect), with: .color(color.swiftUIColor))
            context.stroke(
                Path(ellipseIn: markerRect.insetBy(dx: 1, dy: 1)),
                with: .color(.white.opacity(0.95)),
                lineWidth: max(1.5, displayDiameter * 0.06)
            )
            context.draw(
                Text("\(number)")
                    .font(.system(size: displayDiameter * 0.52, weight: .bold))
                    .foregroundColor(.white),
                at: displayCenter,
                anchor: .center
            )
        case let .batch(_, operations):
            // 预览与导出共用同一份命令数据；batch 递归展开，保证画布与最终图片一致。
            operations.forEach {
                draw(
                    operation: $0,
                    context: &context,
                    displayRect: displayRect,
                    removedRedactionIDs: removedRedactionIDs
                )
            }
        }
    }

    /// Canvas 的 Text 默认按单行绘制；这里使用 CoreText 计算与导出层一致的折行位置，
    /// 再逐行交给 SwiftUI 绘制，保证文字到达选区右侧边界后预览仍保持相同换行。
    private func drawWrappedText(
        _ value: String,
        in rect: CGRect,
        color: RGBAColor,
        fontSize: CGFloat,
        context: inout GraphicsContext
    ) {
        let lines = InlineAnnotationTextLayout.lines(value, in: rect, fontSize: fontSize)
        let textColor = NSColor(
            srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha
        ).cgColor
        context.withCGContext { cgContext in
            for line in lines {
                // 保存 CGContext 当前变换、裁剪和笔触状态；后续 restoreGState 恢复状态，但不会撤销已经绘制的像素。
                cgContext.saveGState()
                cgContext.translateBy(x: line.baseline.x, y: line.baseline.y)
                // 修改上下文的坐标变换矩阵；后续绘制使用变换后的坐标，不会直接改写领域模型中的点。
                cgContext.scaleBy(x: 1, y: -1)
                cgContext.textMatrix = .identity
                cgContext.textPosition = .zero
                cgContext.setFillColor(textColor)
                CTLineDraw(line.text, cgContext)
                cgContext.restoreGState()
            }
        }
    }

    /// 将共享 ArrowGeometry 的顶点映射到显示空间，保证预览与导出的箭头比例来自同一算法。
    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        width: CGFloat,
        mode: ArrowMode,
        context: inout GraphicsContext
    ) {
        switch mode {
        case .line:
            var line = Path()
            line.move(to: start)
            line.addLine(to: end)
            context.stroke(
                line,
                with: .color(color),
                style: SwiftUI.StrokeStyle(lineWidth: width, lineCap: .round)
            )

        case .arrow:
            let points = ArrowGeometry.polygon(from: start, to: end, width: width)
            guard let first = points.first else { return }
            var arrow = Path()
            arrow.move(to: first)
            points.dropFirst().forEach { arrow.addLine(to: $0) }
            arrow.closeSubpath()
            context.fill(arrow, with: .color(color))
        }
    }
}
