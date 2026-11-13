import MacShared
import MacScreenshotSupport
// 阅读路线
// NSTextField 显示选区像素宽高，sizeToFit 测量文本后加上背景留白；位置由选区视图安排。
// NSHostingView 只提供统一背景外壳，标签不参与鼠标命中，也不会写入导出的截图。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import AppKit
import SwiftUI

/// 选框左上角的物理像素尺寸。截图内容来自进入选框前的冻结帧，因此本视图不会进入导出图片。
@MainActor
final class SelectionResolutionBadge: NSView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        layer?.cornerCurve = .continuous
        // 裁掉超出图层边界的内容；若阴影画在同一层，也可能被一起裁掉。
        layer?.masksToBounds = true

        // 复用工具栏外壳，避免 AppKit HUD 材质与工具栏的底色、透明度不一致。
        // 保留原有 AppKit 文本测量及标签尺寸，只替换背景。
        let backgroundView = NSHostingView(
            rootView: Color.clear.screenshotToolbarChrome(cornerRadius: 5)
        )
        backgroundView.frame = bounds
        // AppKit 旧式自动尺寸规则，按父视图尺寸变化伸缩；不是 SwiftUI 的状态属性，也不是完整 Auto Layout 约束。
        backgroundView.autoresizingMask = [.width, .height]
        addSubview(backgroundView)

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        addSubview(label)
    }

    // NSCoder 初始化用于 Storyboard/XIB 解档；本类型仅支持代码创建，下面明确拒绝解档构造路径。
    required init?(coder: NSCoder) {
        nil
    }

    // hitTest 决定哪个 View 接收鼠标；返回 nil 表示此视图不接管该位置的事件，不是把视图设为不可见。
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func update(text: String) {
        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 12, height: 20)
        frame.size = size
        label.frame = CGRect(x: 6, y: 2, width: label.frame.width, height: 16)
    }
}
