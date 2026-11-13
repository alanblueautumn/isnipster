import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 把已渲染截图作为独立浮窗贴在桌面，处理图片展示、窗口拖动和关闭。
// 这张图是导出结果，贴图窗口不再承担原截图会话的选区与标注状态。
// 官方参考（NSWindow 窗口坐标与焦点）：https://developer.apple.com/documentation/appkit/nswindow

import AppKit
import iSnipsterCore

/// 在贴图窗口中显示截图并提供拖动窗口的原生图片视图。
@MainActor
final class PinImageView: NSImageView {
    private let closeButton = NSButton(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Bundle.module 定位 SwiftPM 资源；复制图片后再改尺寸与模板属性，避免修改共享资源对象。
        let closeImage = AppResources.image(named: "lucide-x")
        closeImage?.size = NSSize(width: 14, height: 14)
        closeImage?.isTemplate = true
        closeButton.image = closeImage
        closeButton.imagePosition = .imageOnly
        closeButton.setButtonType(.momentaryPushIn)
        closeButton.isBordered = false
        closeButton.contentTintColor = .white
        closeButton.focusRingType = .none
        closeButton.wantsLayer = true
        // 固定实色底和白色边框，使关闭按钮在任意图片、系统外观下都清晰可见。
        closeButton.layer?.backgroundColor = NSColor(
            calibratedRed: 0.86, green: 0.16, blue: 0.19, alpha: 1
        ).cgColor
        closeButton.layer?.borderColor = NSColor.white.withAlphaComponent(0.9).cgColor
        closeButton.layer?.borderWidth = 1
        closeButton.layer?.shadowColor = NSColor.black.cgColor
        closeButton.layer?.shadowOpacity = 0.35
        closeButton.layer?.shadowRadius = 3
        closeButton.layer?.shadowOffset = CGSize(width: 0, height: -1)
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.toolTip = AppText.text("关闭贴图")
        closeButton.setAccessibilityLabel(AppText.text("关闭贴图"))
        addSubview(closeButton)
    }

    @available(*, unavailable)
    // NSCoder 初始化用于 Storyboard/XIB 解档；本类型仅支持代码创建，下面明确拒绝解档构造路径。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        // 小窗口中限制按钮尺寸和边距；isFlipped 决定 y 轴方向，使按钮始终贴近视觉上的左上角。
        let side = min(26, bounds.width, bounds.height)
        let insetX = min(6, max(0, bounds.width - side))
        let insetY = min(6, max(0, bounds.height - side))
        closeButton.frame = NSRect(
            x: bounds.minX + insetX,
            y: isFlipped ? bounds.minY + insetY : bounds.maxY - insetY - side,
            width: side,
            height: side
        )
        closeButton.layer?.cornerRadius = side / 2
    }

    // 控制非 key 窗口的第一击是否直接触发控件；返回 true 可避免必须先激活再点第二次。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // 将本次按下事件交给系统拖动窗口；无需自行监听每次 mouseDragged 并更新窗口坐标。
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }

    @objc private func closePin() {
        window?.close()
    }
}

/// 展示始终置顶截图贴图的无边框面板。
@MainActor
final class PinnedImagePanel: NSPanel {
    var onClose: (() -> Void)?

    override func close() {
        // 先取出并清空回调，避免关闭过程重入时重复通知；同时释放面板持有的图片与视图。
        let completion = onClose
        onClose = nil
        (contentView as? NSImageView)?.image = nil
        contentView = nil
        super.close()
        completion?()
    }
}
