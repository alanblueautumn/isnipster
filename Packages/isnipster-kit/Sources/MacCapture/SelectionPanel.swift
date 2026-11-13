import MacShared
import MacScreenshotSupport
// 阅读路线
// 每块屏幕的全屏窗口外壳：持有 SelectionOverlayView，配置窗口层级、焦点与显示器身份。
// NSPanel 是 NSWindow 子类；nonactivatingPanel、key window 和 first responder 分别控制激活、键盘窗口和控件焦点。
// 官方参考（NSWindow 窗口坐标与焦点）：https://developer.apple.com/documentation/appkit/nswindow

import AppKit

/// 每块屏幕对应的截图选择面板，承载遮罩并接收鼠标和键盘事件。
@MainActor
final class SelectionPanel: NSPanel {
    let displayID: CGDirectDisplayID?
    let selectionView: SelectionOverlayView

    init(screen: NSScreen, cursorSession: ScreenshotCursorSession) {
        selectionView = SelectionOverlayView(frame: .zero, cursorSession: cursorSession)
        // deviceDescription 是 AppKit 为兼容 Objective-C 保留的异构字典；这里取到的 NSScreenNumber 才能对应 Quartz 显示器 ID。
        displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber)?.uint32Value
        // NSPanel 的指定初始化器必须先由 super 完成原生窗口创建，之后才能设置属性。
        // 这也是之前 “Must call a designated initializer” 错误对应的 Swift 初始化规则。
        super.init(
            contentRect: screen.frame,
            // nonactivatingPanel 允许遮罩接收鼠标和键盘事件，但不会把前台应用的
            // Key Window 状态抢走。这是截图工具保持目标窗口视觉稳定的关键。
            styleMask: [.borderless, .nonactivatingPanel],
            // buffered 表示系统先在后备缓冲绘制、再合成上屏，避免拖动遮罩时直接闪烁。
            backing: .buffered,
            // false 表示立刻创建原生窗口资源；选区出现前必须同步准备好 View 和首帧。
            defer: false
        )
        // `.screenSaver` 层级高于普通 app、菜单和 Dock，保证遮罩能拦住整个桌面；编辑画布再加一层放在其上。
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // 明确禁止本应用遮罩参与系统截图；这是窗口级隐私/捕获属性，不影响屏幕显示。
        sharingType = .none
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // iSnipster 此时刻意不激活，因此面板不能跟随应用失活自动隐藏。
        hidesOnDeactivate = false

        // 不依赖 NSWindow 在替换 contentView 时“顺便调整尺寸”。无边框 NSPanel 下，
        // 一个以 .zero 创建且没有 autoresizingMask 的 View 可能保持零尺寸；窗口虽然在，
        // 但 AppKit hit-test 找不到该 View，于是 mouseDown/mouseDragged/mouseUp 都不会调用。
        // Java 对照：类似 JPanel 已加入 JFrame，但 bounds 仍是 (0, 0, 0, 0)。
        selectionView.frame = NSRect(origin: .zero, size: contentLayoutRect.size)
        // AppKit 旧式自动尺寸规则，按父视图尺寸变化伸缩；不是 SwiftUI 的状态属性，也不是完整 Auto Layout 约束。
        selectionView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        contentView = selectionView

        // 这些默认值在这里显式声明，避免以后调整 Panel styleMask 时意外穿透鼠标事件。
        ignoresMouseEvents = false
        becomesKeyOnlyIfNeeded = false
        isMovable = false
        isMovableByWindowBackground = false
        // 默认 NSWindow 为省电可能不派发纯移动事件；选区需要它更新悬停窗口、光标和像素放大镜。
        acceptsMouseMovedEvents = true
    }

    // borderless panel 的默认值是 false。允许成为 key 后，窗口才可成为键盘事件响应链的起点。
    override var canBecomeKey: Bool { true }

    override func becomeKey() {
        super.becomeKey()
        // 全局快捷键启动第二次截图时，key window 的切换可能晚于同步光标设置；
        // 在系统正式确认 Panel 成为 key 的生命周期回调中再声明一次，消除时序差异。
        selectionView.activateWindowSelectionCursor()
    }
}
