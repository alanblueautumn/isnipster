import MacShared
// 阅读路线
// 放大镜把附近像素块放大显示，并标出当前像素；它是辅助视图，不会重新读取系统屏幕。
// 最近邻显示适合观察像素格；文字与边框使用 point，取样仍使用原图 pixel。
// 官方参考（CALayer 显示内容）：https://developer.apple.com/documentation/quartzcore/calayer

import AppKit
import ColorPickerFeature
import CoreText

/// 初选复制颜色和编辑吸管共用的只读像素放大镜，不参与鼠标命中。
@MainActor
public final class ScreenshotPixelMagnifierView: NSView {
    private var sampleImage: CGImage?
    private var color: SampledColor?
    private var copiedHex: String?
    private var pixelInSample: CGPoint = .zero
    private var showsCopyShortcut = false
    private static let imageSide: CGFloat = 150
    private static let footerHeight: CGFloat = 28
    private static let labelFont = CTFontCreateWithName("Menlo-Medium" as CFString, 11, nil)
    public static let preferredSize = NSSize(width: imageSide, height: imageSide + footerHeight)

    /// AppKit 左下原点；初选子视图和编辑浮层共用同一套边缘避让。
    public static func positionedFrame(near point: CGPoint, within bounds: CGRect) -> CGRect {
        let padding: CGFloat = 8
        let gap: CGFloat = 18
        let size = preferredSize
        var x = point.x + gap
        if x + size.width > bounds.maxX - padding { x = point.x - gap - size.width }
        var y = point.y - gap - size.height
        if y < bounds.minY + padding { y = point.y + gap }
        return CGRect(
            x: min(max(x, bounds.minX + padding), max(bounds.minX + padding, bounds.maxX - size.width - padding)),
            y: min(max(y, bounds.minY + padding), max(bounds.minY + padding, bounds.maxY - size.height - padding)),
            width: size.width,
            height: size.height
        )
    }

    /// 释放当前样本并恢复空状态；只是关闭辅助显示，不修改冻结原图。
    public func clear() {
        sampleImage = nil
        color = nil
        copiedHex = nil
        needsDisplay = true
    }

    // hitTest 决定哪个 View 接收鼠标；返回 nil 表示此视图不接管该位置的事件，不是把视图设为不可见。
    public override func hitTest(_ point: NSPoint) -> NSView? {
        // 放大镜只负责显示；返回 nil 后，点击和拖动会继续落到父级选区 View。
        nil
    }

    /// 接收已经裁出的像素块与中心颜色，刷新显示；采样计算由调用方完成。
    public func update(sample: ScreenshotPixelSample, showsCopyShortcut: Bool = false) {
        sampleImage = sample.image
        color = sample.color
        pixelInSample = sample.pixelInSample
        self.showsCopyShortcut = showsCopyShortcut
        copiedHex = nil
        needsDisplay = true
    }

    /// 给当前取色操作显示已复制反馈，不负责真正写入系统剪贴板。
    public func showCopied(hex: String) {
        copiedHex = hex
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let container = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        container.addClip()
        NSColor.windowBackgroundColor.withAlphaComponent(0.97).setFill()
        container.fill()

        let imageRect = NSRect(
            x: bounds.minX, y: bounds.minY + Self.footerHeight,
            width: Self.imageSide, height: Self.imageSide
        )
        if let sampleImage {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: imageRect).addClip()
            // nearest 保留像素硬边，不做双线性平滑；否则放大镜会看起来模糊，无法精确取色。
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(
                cgImage: sampleImage,
                size: NSSize(width: sampleImage.width, height: sampleImage.height)
            ).draw(in: imageRect)

            // 标记实际取色像素，裁剪区域在图片边缘发生偏移时仍与颜色值一致。
            let pixelWidth = imageRect.width / CGFloat(max(sampleImage.width, 1))
            let pixelHeight = imageRect.height / CGFloat(max(sampleImage.height, 1))
            let markerRect = NSRect(
                x: imageRect.minX + pixelInSample.x * pixelWidth,
                y: imageRect.maxY - (pixelInSample.y + 1) * pixelHeight,
                width: pixelWidth,
                height: pixelHeight
            )
            let marker = NSBezierPath(rect: markerRect)
            NSColor.black.withAlphaComponent(0.75).setStroke()
            marker.lineWidth = 3
            marker.stroke()
            NSColor.white.setStroke()
            marker.lineWidth = 1
            marker.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 9, yRadius: 9)
        border.lineWidth = 1
        border.stroke()

        guard let color else { return }
        let hex = color.formatted(as: .hex)
        let swatchRect = NSRect(x: 8, y: 5, width: 18, height: 18)
        let swatch = NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4)
        NSColor(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: 1
        ).setFill()
        swatch.fill()
        NSColor.separatorColor.setStroke()
        swatch.lineWidth = 1
        swatch.stroke()

        let label = copiedHex.map { "已复制 \($0)" } ?? (showsCopyShortcut ? "\(hex)  ⌘C" : hex)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        // 崩溃日志指向 NSString 绘制时的系统字体属性转换；改用具名字体和原生
        // CoreText 属性直接排版，避开该 AppKit 转换路径。
        let attributedLabel = NSAttributedString(
            string: label,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): Self.labelFont,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.labelColor.cgColor
            ]
        )
        let line = CTLineCreateWithAttributedString(attributedLabel)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        context.saveGState()
        defer { context.restoreGState() }
        context.textMatrix = .identity
        context.textPosition = CGPoint(
            x: bounds.minX + 33,
            y: bounds.minY + (Self.footerHeight - ascent - descent) / 2 + descent
        )
        CTLineDraw(line, context)
    }
}
