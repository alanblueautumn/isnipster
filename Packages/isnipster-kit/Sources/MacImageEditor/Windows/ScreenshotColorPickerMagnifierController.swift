import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 跟踪画布鼠标位置，在独立面板中展示附近像素；取样来源由闭包提供当前图片。
// 开始与结束对称安装/移除监听，关闭会话后不能让辅助窗口或定时刷新继续存活。
// 官方参考（NSWindow 窗口坐标与焦点）：https://developer.apple.com/documentation/appkit/nswindow

import AppKit

/// 编辑吸管的只读浮层，独立于画布尺寸，不接管键盘焦点或鼠标事件。
@MainActor
final class ScreenshotColorPickerMagnifierController {
    private weak var canvasWindow: NSWindow?
    private weak var canvasView: NSView?
    private let imageProvider: () -> CGImage?
    private var panel: NSPanel?
    private let magnifierView = ScreenshotPixelMagnifierView(
        frame: CGRect(origin: .zero, size: ScreenshotPixelMagnifierView.preferredSize)
    )
    private var mouseMonitor: Any?
    private var isDismissed = false

    init(canvasWindow: NSWindow, canvasView: NSView?, imageProvider: @escaping () -> CGImage?) {
        self.canvasWindow = canvasWindow
        self.canvasView = canvasView
        self.imageProvider = imageProvider
    }

    func start() {
        guard mouseMonitor == nil, !isDismissed else { return }
        // local monitor 在本应用派发事件前执行；返回 nil 消费事件，返回 event 才继续交给 responder chain。
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .leftMouseUp, .mouseEntered, .mouseExited]
        ) { [weak self] event in
            self?.refresh()
            return event
        }
        refresh()
    }

    func refresh() {
        guard !isDismissed, let window = canvasWindow, let canvasView,
              window.isVisible, !window.ignoresMouseEvents,
              let image = imageProvider() else {
            hide()
            return
        }
        let point = NSEvent.mouseLocation
        // 坐标转换中的 nil 表示所属窗口坐标系，不表示屏幕坐标；跨到屏幕还需窗口转换 API。
        let localPoint = canvasView.convert(window.convertPoint(fromScreen: point), from: nil)
        let imagePoint = CGPoint(
            x: localPoint.x - canvasView.bounds.minX,
            y: canvasView.isFlipped
                ? localPoint.y - canvasView.bounds.minY
                : canvasView.bounds.maxY - localPoint.y
        )
        guard canvasView.bounds.contains(localPoint), isMouseOverCanvas(at: point),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }),
              let sample = ScreenshotPixelSampler.magnifiedSample(
                in: image,
                at: imagePoint,
                displayedAt: canvasView.bounds.size
              ) else {
            hide()
            return
        }

        let frame = ScreenshotPixelMagnifierView.positionedFrame(near: point, within: screen.frame)
        let panel = self.panel ?? makePanel(attachedTo: window, frame: frame)
        magnifierView.update(sample: sample)
        panel.setFrame(frame, display: false)
        // 把窗口放到前面显示，不等于激活整个应用或把某个输入控件设为 first responder。
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    /// 工具栏可覆盖画布边缘，不能仅用画布矩形判断是否还在取色。
    private func isMouseOverCanvas(at point: CGPoint) -> Bool {
        guard let numbers = NSWindow.windowNumbers(options: []) else { return false }
        for number in numbers {
            guard let window = NSApp.window(withWindowNumber: number.intValue),
                  window.isVisible, !window.ignoresMouseEvents,
                  window.frame.contains(point) else { continue }
            return window === canvasWindow
        }
        return false
    }

    private func makePanel(attachedTo window: NSWindow, frame: CGRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // level 决定窗口相对其他层级的前后位置；同层窗口的顺序还由 orderFront/子窗口关系决定。
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 2)
        // isOpaque 是给合成器的“不透明”声明，不是设置颜色；透明窗口还要使用透明 backgroundColor。
        panel.isOpaque = false
        // 将窗口/图层底色设为透明；最终是否透出下层还取决于内容视图和 isOpaque 的配置。
        panel.backgroundColor = .clear
        // 这是系统窗口阴影开关；SwiftUI 内容若自己绘阴影，两者叠加可能出现双重边缘。
        panel.hasShadow = false
        // 控制整个窗口是否接收鼠标；设为 true 时事件可落到下层窗口，不能把它当作阻止点击穿透。
        panel.ignoresMouseEvents = true
        // 决定应用失去激活状态时是否自动隐藏面板；隐藏不等于关闭，也不会自动释放会话状态。
        panel.hidesOnDeactivate = false
        // 设置 AppKit 的窗口共享策略；它不是对所有屏幕捕获方式都有效的像素保密保证。
        panel.sharingType = .none
        // 指定系统对窗口显示/隐藏采用的动画行为；与内容图层 CABasicAnimation 是不同层面的动画。
        panel.animationBehavior = .none
        // 控制窗口在 Spaces 与全屏空间中的参与方式；不是 SwiftUI 中的子视图布局属性。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // AppKit 旧式自动尺寸规则，按父视图尺寸变化伸缩；不是 SwiftUI 的状态属性，也不是完整 Auto Layout 约束。
        magnifierView.autoresizingMask = [.width, .height]
        panel.contentView = magnifierView
        // 建立原生父子窗口关系以协调层级与移动；子窗口仍是独立 NSWindow，不是普通子 View。
        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        return panel
    }

    private func hide() {
        // orderOut 只把窗口移出屏幕，不销毁对象；若还持有 contentView 或控制器，相关资源仍然存在。
        panel?.orderOut(nil)
        magnifierView.clear()
    }

    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        if let panel {
            // 解除窗口关系后再关闭/释放子窗口，避免父窗口继续影响已结束的浮层。
            canvasWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panel = nil
        magnifierView.clear()
        canvasWindow = nil
        canvasView = nil
    }
}
