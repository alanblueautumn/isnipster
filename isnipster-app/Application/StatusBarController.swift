import AppKit
import CoreGraphics
import MacPlatform
import SwiftUI

/// 菜单是不激活应用的面板，第一次点击应直接执行按钮操作。
// 这里直接指定 MenuBarContentView，只服务状态栏菜单，无需为其他根 View 提供泛型参数。
@MainActor
private final class StatusMenuHostingView: NSHostingView<MenuBarContentView> {
    /// NSHostingView 把 SwiftUI 根 View 放进 AppKit 的 NSView 树；重写此方法能让非 key 窗口的第一次点击直接派发给按钮。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// 创建状态栏图标并管理自定义弹出菜单及其外部点击关闭行为。
@MainActor
final class StatusBarController: NSObject {
    private static let menuContentSize = NSSize(width: 220, height: 154)
    // 顶部不留间距，让菜单玻璃表面直接贴住状态栏；其他方向保留合成空间。
    private static let glassInsets = NSEdgeInsets(
        top: 0,
        left: 8,
        bottom: 8,
        right: 8
    )

    private let statusItem: NSStatusItem
    private let panel: NSPanel
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    init(model: AppModel) {
        // NSStatusBar 是系统菜单栏服务；statusItem 不是普通窗口控件，系统负责把它放到菜单栏可用位置。
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let panelSize = NSSize(
            width: Self.menuContentSize.width
                + Self.glassInsets.left
                + Self.glassInsets.right,
            height: Self.menuContentSize.height
                + Self.glassInsets.top
                + Self.glassInsets.bottom
        )
        // NSPanel 是 NSWindow 的轻量子类，适用于检查器、浮层和菜单式界面。
        // `.nonactivatingPanel` 允许点击内容却不抢走原前台应用的激活状态。
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        let contentView = MenuBarContentView(
            model: model,
            onDismiss: { [weak self] in self?.hidePanel() }
        )
        let hostingView = StatusMenuHostingView(rootView: contentView)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        // AppKit 旧式自动尺寸规则，按父视图尺寸变化伸缩；不是 SwiftUI 的状态属性，也不是完整 Auto Layout 约束。
        hostingView.autoresizingMask = [.width, .height]
        // 让 NSView 使用 backing layer，后续才能设置 CALayer 的圆角、内容与路径；视图和图层仍是两套对象。
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor

        // 菜单表面、圆角和阴影全部由 SwiftUI 的原生 Liquid Glass 负责；
        // AppKit 只保留透明窗口、状态栏定位和点击事件生命周期。
        panel.contentView = hostingView
        // isOpaque 是给合成器的“不透明”声明，不是设置颜色；透明窗口还要使用透明 backgroundColor。
        panel.isOpaque = false
        // 将窗口/图层底色设为透明；最终是否透出下层还取决于内容视图和 isOpaque 的配置。
        panel.backgroundColor = .clear
        // 原生玻璃视图已经按圆角轮廓绘制阴影，避免再叠加矩形 NSWindow 阴影。
        panel.hasShadow = false
        // window level 决定与其他窗口的 Z 轴顺序；`.popUpMenu` 高于普通窗口，但不是永久置顶的屏保层。
        panel.level = .popUpMenu
        // 控制窗口在 Spaces 与全屏空间中的参与方式；不是 SwiftUI 中的子视图布局属性。
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .fullScreenAuxiliary]
        // 决定应用失去激活状态时是否自动隐藏面板；隐藏不等于关闭，也不会自动释放会话状态。
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        // 允许面板仅在控件需要键盘时取得 key；按钮点击与输入框输入不一定需要相同的焦点策略。
        panel.becomesKeyOnlyIfNeeded = true

        guard let button = statusItem.button else { return }
        let image = Self.makeMenuBarIcon()
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = AppText.text("iSnipster")
        // target/action 是 AppKit 的事件模型，类似 Java Swing 的 listener：按钮鼠标事件发生后，运行时调用 target 的 selector。
        button.target = self
        button.action = #selector(togglePanel(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private static func makeMenuBarIcon() -> NSImage {
        let designSize = NSSize(width: 18, height: 18)
        let size = NSSize(width: 20, height: 20)
        // NSImage 的 drawingHandler 是“按需绘制”回调；系统需要各分辨率图像时会给出当前图形上下文。
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            // CGContext 是 Core Graphics 绘图上下文。saveGState/restoreGState 成对保存颜色、缩放、裁剪等状态，
            // 等价于 HTML Canvas 的 save()/restore()，防止本图标的缩放影响同一上下文后续绘制。
            context.saveGState()
            // 修改上下文的坐标变换矩阵；后续绘制使用变换后的坐标，不会直接改写领域模型中的点。
            context.scaleBy(
                x: size.width / designSize.width,
                y: size.height / designSize.height
            )
            defer { context.restoreGState() }

            NSColor.black.setStroke()

            let brackets = NSBezierPath()
            brackets.lineWidth = 1.45
            brackets.lineCapStyle = .round
            brackets.lineJoinStyle = .round
            let cornerRadius: CGFloat = 0.75

            brackets.move(to: NSPoint(x: 6.25, y: 15))
            brackets.line(to: NSPoint(x: 3 + cornerRadius, y: 15))
            brackets.curve(
                to: NSPoint(x: 3, y: 15 - cornerRadius),
                controlPoint1: NSPoint(x: 3.34, y: 15),
                controlPoint2: NSPoint(x: 3, y: 14.66)
            )
            brackets.line(to: NSPoint(x: 3, y: 11.75))

            brackets.move(to: NSPoint(x: 11.75, y: 15))
            brackets.line(to: NSPoint(x: 15 - cornerRadius, y: 15))
            brackets.curve(
                to: NSPoint(x: 15, y: 15 - cornerRadius),
                controlPoint1: NSPoint(x: 14.66, y: 15),
                controlPoint2: NSPoint(x: 15, y: 14.66)
            )
            brackets.line(to: NSPoint(x: 15, y: 11.75))

            brackets.move(to: NSPoint(x: 3, y: 6.25))
            brackets.line(to: NSPoint(x: 3, y: 3 + cornerRadius))
            brackets.curve(
                to: NSPoint(x: 3 + cornerRadius, y: 3),
                controlPoint1: NSPoint(x: 3, y: 3.34),
                controlPoint2: NSPoint(x: 3.34, y: 3)
            )
            brackets.line(to: NSPoint(x: 6.25, y: 3))

            brackets.move(to: NSPoint(x: 15, y: 6.25))
            brackets.line(to: NSPoint(x: 15, y: 3 + cornerRadius))
            brackets.curve(
                to: NSPoint(x: 15 - cornerRadius, y: 3),
                controlPoint1: NSPoint(x: 15, y: 3.34),
                controlPoint2: NSPoint(x: 14.66, y: 3)
            )
            brackets.line(to: NSPoint(x: 11.75, y: 3))
            brackets.stroke()

            let text = NSAttributedString(
                string: "ST",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 7.4, weight: .bold),
                    .foregroundColor: NSColor.black,
                    .kern: -0.65
                ]
            )
            let textSize = text.size()
            text.draw(at: NSPoint(
                x: (designSize.width - textSize.width) / 2,
                y: (designSize.height - textSize.height) / 2 + 0.25
            ))
            return true
        }
        // 模板图不固定黑色像素，菜单栏会按浅色/深色外观自动染色；因此绘制颜色只是轮廓基准。
        image.isTemplate = true
        image.accessibilityDescription = "iSnipster"
        return image
    }

    @objc private func togglePanel(_ sender: NSStatusBarButton) {
        panel.isVisible ? hidePanel() : showPanel(relativeTo: sender)
    }

    private func showPanel(relativeTo button: NSStatusBarButton) {
        guard let buttonWindow = button.window else { return }
        // AppKit 坐标必须逐级转换：button.bounds 是局部坐标，nil 表示转到所属 window，
        // convertToScreen 再转成桌面全局坐标，才能用于 NSPanel 的 setFrameOrigin。
        let buttonFrame = button.convert(button.bounds, to: nil)
        // 把窗口内坐标转成桌面全局坐标；多屏桌面可能包含负坐标，不能假定屏幕都从 (0,0) 开始。
        let screenFrame = buttonWindow.convertToScreen(buttonFrame)
        let panelSize = panel.frame.size
        let visibleFrame = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        // 默认让菜单主体左边缘与状态栏图标左边缘对齐；右侧空间不足时整体向左，
        // 让面板右边缘铺到当前屏幕可用区域的右边界。
        let x = min(
            max(
                screenFrame.minX - Self.glassInsets.left,
                visibleFrame.minX
            ),
            visibleFrame.maxX - panelSize.width
        )
        // visibleFrame.maxY 是菜单栏下边界；顶部 inset 为 0，因此菜单主体直接贴紧它。
        let y = max(
            visibleFrame.minY,
            visibleFrame.maxY - panelSize.height
        )
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        // 把窗口放到前面显示，不等于激活整个应用或把某个输入控件设为 first responder。
        panel.orderFrontRegardless()
        installDismissMonitors()
    }

    private func hidePanel() {
        // orderOut 只把窗口移出屏幕，不销毁对象；若还持有 contentView 或控制器，相关资源仍然存在。
        panel.orderOut(nil)
        removeDismissMonitors()
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        // local monitor 能看见本应用事件且可返回 nil 消费；global monitor 只通知其他应用的点击，不能修改事件。
        // 两者合用，浮层无论在自己窗口内外点击都能关闭。
        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.window !== panel, event.window !== statusItem.button?.window {
                hidePanel()
            }
            return event
        }
        // global monitor 观察其他应用的匹配事件，不能拦截或改写事件；结束监听时须移除返回的 token。
        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            self?.hidePanel()
        }
    }

    private func removeDismissMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }
}
