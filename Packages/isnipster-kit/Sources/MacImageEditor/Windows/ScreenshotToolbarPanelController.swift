import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 负责主/副工具栏窗口的尺寸、相对选区位置、层级与移动；View 只提供内容。
// 子窗口不是 SwiftUI 子 View：窗口之间的位置、焦点和显隐需要 AppKit 显式协调。
// 官方参考（NSWindow 窗口坐标与焦点）：https://developer.apple.com/documentation/appkit/nswindow

import AppKit
import SwiftUI
import iSnipsterCore

/// 管理截图主工具栏、属性栏和悬停提示的窗口生命周期与布局。
@MainActor
final class ScreenshotToolbarPanelController {
    private let session: InlineEditorSession
    private let shortcuts: [ScreenshotToolShortcutAction: HotKeyDescriptor]
    private let onAction: (ScreenshotToolbarAction) -> Void
    private let onCancel: () -> Void

    private weak var parentWindow: NSWindow?
    private var selectionFrame: CGRect = .zero
    private var toolbarPanel: NSPanel?
    private var stylePanel: NSPanel?
    private var tooltipPanel: NSPanel?
    private weak var tooltipLabel: NSTextField?
    private var tooltipPresentationTask: Task<Void, Never>?

    init(
        session: InlineEditorSession,
        shortcuts: [ScreenshotToolShortcutAction: HotKeyDescriptor],
        onAction: @escaping (ScreenshotToolbarAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.session = session
        self.shortcuts = shortcuts
        self.onAction = onAction
        self.onCancel = onCancel
    }

    func show(attachedTo parentWindow: NSWindow, selectionFrame: CGRect) {
        guard toolbarPanel == nil else { return }
        self.parentWindow = parentWindow
        self.selectionFrame = selectionFrame

        let frame = toolbarLayout().main
        let panel = makePanel(frame: frame, levelOffset: 2)
        let hostingView = EditorFirstMouseHostingView(
            rootView: ScreenshotToolbarView(
                session: session,
                shortcuts: shortcuts,
                onAction: onAction,
                onHoverHint: { [weak self] hint in
                    self?.showTooltip(hint)
                }
            ),
            cursorSession: session.cursorSession,
            cursorContext: { _ in .toolbar }
        )
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        // AppKit 旧式自动尺寸规则，按父视图尺寸变化伸缩；不是 SwiftUI 的状态属性，也不是完整 Auto Layout 约束。
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        toolbarPanel = panel

        // 建立原生父子窗口关系以协调层级与移动；子窗口仍是独立 NSWindow，不是普通子 View。
        parentWindow.addChildWindow(panel, ordered: .above)
        // 把窗口放到前面显示，不等于激活整个应用或把某个输入控件设为 first responder。
        panel.orderFrontRegardless()
    }

    /// 选区移动或缩放后重算主、副工具栏位置；工具参数与文档不随窗口移动改变。
    func updateSelectionFrame(_ selectionFrame: CGRect) {
        self.selectionFrame = selectionFrame
        showTooltip(nil)
        let layout = toolbarLayout()
        toolbarPanel?.setFrame(layout.main, display: false)
        stylePanel?.setFrame(layout.style, display: false)
    }

    /// 展示当前工具对应的副栏并更新布局；副栏是独立窗口，不是主栏内部增加一行。
    func showStylePanel() {
        guard let parentWindow else { return }
        // 翻译栏与标注栏高度不同，切换时主、副栏必须按同一组布局同步定位。
        let layout = toolbarLayout()
        toolbarPanel?.setFrame(layout.main, display: false)
        let frame = layout.style
        if let stylePanel {
            stylePanel.setFrame(frame, display: true)
            return
        }
        let panel = makePanel(frame: frame, levelOffset: 2)
        // 主、副工具栏使用同一个区域适配器；焦点回到画布时，鼠标停在这里仍显示箭头。
        let hostingView = EditorFirstMouseHostingView(
            rootView: ScreenshotStylePanelView(session: session, onAction: onAction),
            cursorSession: session.cursorSession,
            cursorContext: { _ in .toolbar }
        )
        // 尺寸由 toolbarLayout 统一管理，避免不同工具的内容反向改变面板宽度。
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        stylePanel = panel

        parentWindow.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
    }

    /// 隐藏副工具栏，保留主栏操作；例如 OCR 模式不需要笔触属性控件。
    func hideStylePanel() {
        guard let stylePanel else { return }
        // 解除窗口关系后再关闭/释放子窗口，避免父窗口继续影响已结束的浮层。
        parentWindow?.removeChildWindow(stylePanel)
        close(panel: stylePanel)
        self.stylePanel = nil
    }

    /// 判断事件窗口是否由本工具栏控制器持有，供截图会话键盘过滤使用。
    func owns(window: NSWindow?) -> Bool {
        guard let window else { return false }
        return window === toolbarPanel || window === stylePanel || window === tooltipPanel
    }

    /// 关闭主栏、副栏及提示窗口，并断开父子窗口关系，结束当前工具栏生命周期。
    func dismiss() {
        tooltipPresentationTask?.cancel()
        tooltipPresentationTask = nil

        if let toolbarPanel {
            parentWindow?.removeChildWindow(toolbarPanel)
            close(panel: toolbarPanel)
        }
        if let stylePanel {
            parentWindow?.removeChildWindow(stylePanel)
            close(panel: stylePanel)
        }
        if let tooltipPanel {
            parentWindow?.removeChildWindow(tooltipPanel)
            close(panel: tooltipPanel)
        }

        toolbarPanel = nil
        stylePanel = nil
        tooltipPanel = nil
        tooltipLabel = nil
        parentWindow = nil
    }

    private func makePanel(frame: CGRect, levelOffset: Int) -> ScreenshotOverlayPanel {
        let panel = ScreenshotOverlayPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // level 决定窗口相对其他层级的前后位置；同层窗口的顺序还由 orderFront/子窗口关系决定。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + levelOffset)
        panel.isFloatingPanel = true
        // isOpaque 是给合成器的“不透明”声明，不是设置颜色；透明窗口还要使用透明 backgroundColor。
        panel.isOpaque = false
        // 将窗口/图层底色设为透明；最终是否透出下层还取决于内容视图和 isOpaque 的配置。
        panel.backgroundColor = .clear
        // 这是系统窗口阴影开关；SwiftUI 内容若自己绘阴影，两者叠加可能出现双重边缘。
        panel.hasShadow = false
        // 设置 AppKit 的窗口共享策略；它不是对所有屏幕捕获方式都有效的像素保密保证。
        panel.sharingType = .none
        // 指定系统对窗口显示/隐藏采用的动画行为；与内容图层 CABasicAnimation 是不同层面的动画。
        panel.animationBehavior = .none
        // 控制窗口在 Spaces 与全屏空间中的参与方式；不是 SwiftUI 中的子视图布局属性。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = onCancel
        return panel
    }

    private func close(panel: NSPanel) {
        // orderOut 只把窗口移出屏幕，不销毁对象；若还持有 contentView 或控制器，相关资源仍然存在。
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    private func showTooltip(_ text: String?) {
        tooltipPresentationTask?.cancel()
        tooltipPresentationTask = nil

        guard let text, !text.isEmpty else {
            tooltipPanel?.orderOut(nil)
            return
        }

        tooltipPresentationTask = Task { @MainActor [weak self] in
            do {
                // sleep 让当前 Task 挂起，其他任务仍可运行；try 说明等待期间取消可能抛出 CancellationError。
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                self?.presentTooltip(text)
            } catch {
                return
            }
        }
    }

    private func presentTooltip(_ text: String) {
        guard let toolbarPanel else { return }

        let panel: NSPanel
        let label: NSTextField
        if let existingPanel = tooltipPanel, let existingLabel = tooltipLabel {
            panel = existingPanel
            label = existingLabel
        } else {
            panel = makePanel(
                frame: CGRect(x: 0, y: 0, width: 80, height: 26),
                levelOffset: 3
            )
            // 控制整个窗口是否接收鼠标；设为 true 时事件可落到下层窗口，不能把它当作阻止点击穿透。
            panel.ignoresMouseEvents = true

            let effectView = NSVisualEffectView(frame: CGRect(x: 0, y: 0, width: 80, height: 26))
            effectView.material = .hudWindow
            effectView.blendingMode = .behindWindow
            effectView.state = .active
            effectView.appearance = NSAppearance(named: .darkAqua)
            // 让 NSView 使用 backing layer，后续才能设置 CALayer 的圆角、内容与路径；视图和图层仍是两套对象。
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = 7
            effectView.layer?.cornerCurve = .continuous
            // 裁掉超出图层边界的内容；若阴影画在同一层，也可能被一起裁掉。
            effectView.layer?.masksToBounds = true

            label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12, weight: .medium)
            label.textColor = .white
            label.alignment = .center
            effectView.addSubview(label)
            panel.contentView = effectView

            parentWindow?.addChildWindow(panel, ordered: .above)
            tooltipPanel = panel
            tooltipLabel = label
        }

        label.stringValue = text
        label.sizeToFit()
        let size = CGSize(width: label.frame.width + 20, height: 26)
        label.frame = CGRect(x: 10, y: 5, width: label.frame.width, height: 16)
        panel.setContentSize(size)
        panel.contentView?.frame = CGRect(origin: .zero, size: size)
        if let effectView = panel.contentView as? NSVisualEffectView {
            let mask = CAShapeLayer()
            mask.frame = CGRect(origin: .zero, size: size)
            mask.path = CGPath(
                roundedRect: mask.bounds,
                cornerWidth: 7,
                cornerHeight: 7,
                transform: nil
            )
            effectView.layer?.mask = mask
        }

        let visible = toolbarPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? toolbarPanel.frame
        let mouseX = NSEvent.mouseLocation.x
        let x = min(max(mouseX - size.width / 2, visible.minX + 4), visible.maxX - size.width - 4)
        let aboveY = toolbarPanel.frame.maxY + 5
        let y = aboveY + size.height <= visible.maxY - 4
            ? aboveY
            : toolbarPanel.frame.minY - size.height - 5
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        panel.orderFrontRegardless()
    }

    /// 按下方 → 上方 → 左侧 → 右侧尝试外部布局，空间不足时退回选区内部底部。
    /// 所有结果均是 AppKit 全局 point；主副栏一起计算，避免分别定位后互相覆盖。
    private func toolbarLayout() -> (main: CGRect, style: CGRect) {
        let screen = NSScreen.screens.first(where: { $0.frame.intersects(selectionFrame) })
            ?? NSScreen.main
        let visible = (screen?.visibleFrame ?? selectionFrame).insetBy(dx: 8, dy: 8)
        let mainHeight: CGFloat = 42
        let mainWidth = min(624, visible.width)
        let preferredStyleSize = ScreenshotStylePanelView.preferredSize(for: session)
        let styleHeight = preferredStyleSize.height
        let styleWidth = min(preferredStyleSize.width, mainWidth)
        let displayScale = max(screen?.backingScaleFactor ?? 1, 1)
        let baseGap = 8 / displayScale
        let imageGap = baseGap * 2
        let insideEdgeInset = max(2 / displayScale, 1)
        let styleGap = baseGap
        let verticalStackHeight = mainHeight + styleGap + styleHeight
        let requiredToolbarSpace = imageGap + verticalStackHeight
        let proposedX = selectionFrame.midX - mainWidth / 2
        let x = min(max(proposedX, visible.minX), visible.maxX - mainWidth)

        let availableBelow = selectionFrame.minY - visible.minY
        let availableAbove = visible.maxY - selectionFrame.maxY
        let availableLeft = selectionFrame.minX - visible.minX
        let availableRight = visible.maxX - selectionFrame.maxX

        func layoutBelow() -> (main: CGRect, style: CGRect) {
            let main = CGRect(
                x: x,
                y: selectionFrame.minY - imageGap - mainHeight,
                width: mainWidth,
                height: mainHeight
            )
            let style = CGRect(
                x: x,
                y: main.minY - styleGap - styleHeight,
                width: styleWidth,
                height: styleHeight
            )
            return (main, style)
        }

        func layoutAbove() -> (main: CGRect, style: CGRect) {
            let main = CGRect(
                x: x,
                y: selectionFrame.maxY + imageGap,
                width: mainWidth,
                height: mainHeight
            )
            let style = CGRect(
                x: x,
                y: main.maxY + styleGap,
                width: styleWidth,
                height: styleHeight
            )
            return (main, style)
        }

        func layoutOnSide(isLeft: Bool) -> (main: CGRect, style: CGRect) {
            let proposedBottom = selectionFrame.midY - verticalStackHeight / 2
            let groupBottom = min(
                max(proposedBottom, visible.minY),
                visible.maxY - verticalStackHeight
            )
            let mainX = isLeft
                ? selectionFrame.minX - imageGap - mainWidth
                : selectionFrame.maxX + imageGap
            let style = CGRect(
                x: mainX,
                y: groupBottom,
                width: styleWidth,
                height: styleHeight
            )
            let main = CGRect(
                x: mainX,
                y: style.maxY + styleGap,
                width: mainWidth,
                height: mainHeight
            )
            return (main, style)
        }

        func layoutInsideBottom() -> (main: CGRect, style: CGRect) {
            // 内置回退允许覆盖 Dock 区域，按完整屏幕边界定位，确保贴近选区右下边缘。
            let insideBounds = (screen?.frame ?? selectionFrame)
                .insetBy(dx: insideEdgeInset, dy: insideEdgeInset)
            let insideX = min(
                max(selectionFrame.maxX - insideEdgeInset - mainWidth, insideBounds.minX),
                insideBounds.maxX - mainWidth
            )
            let mainY = min(
                max(selectionFrame.minY + insideEdgeInset, insideBounds.minY),
                insideBounds.maxY - mainHeight
            )
            let main = CGRect(
                x: insideX,
                y: mainY,
                width: mainWidth,
                height: mainHeight
            )
            let proposedStyleY = main.maxY + styleGap
            let style = CGRect(
                x: main.maxX - styleWidth,
                y: min(proposedStyleY, insideBounds.maxY - styleHeight),
                width: styleWidth,
                height: styleHeight
            )
            return (main, style)
        }

        if availableBelow >= requiredToolbarSpace {
            return layoutBelow()
        }
        if availableAbove >= requiredToolbarSpace {
            return layoutAbove()
        }
        if availableLeft >= imageGap + mainWidth, visible.height >= verticalStackHeight {
            return layoutOnSide(isLeft: true)
        }
        if availableRight >= imageGap + mainWidth, visible.height >= verticalStackHeight {
            return layoutOnSide(isLeft: false)
        }
        return layoutInsideBottom()
    }
}
