import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 将 SwiftUI 画布放入 AppKit 窗口，并在原生鼠标跟踪回调中更新光标。
// 窗口是否接受键盘、View 是否接受首击、鼠标区域显示何种光标，是三个不同的 AppKit 扩展点。
// 官方参考（NSHostingView）：https://developer.apple.com/documentation/swiftui/nshostingview

import AppKit
import SwiftUI

/// 承载截图编辑画布并统一处理 Escape 等窗口级事件的无边框面板。
@MainActor
final class ScreenshotOverlayPanel: NSPanel {
    /// 编辑会话的顶层取消动作。把 Esc 放在 AppKit 窗口层处理，不依赖当前 SwiftUI
    /// First Responder 是 Canvas、按钮、ColorPicker 还是 TextField。
    var onEscape: (() -> Void)?

    // 无边框 Panel 默认不能成为 key window；重写后画布才能收到键盘和文本输入。
    override var canBecomeKey: Bool { true }
    // main window 表示应用的主要文档窗口；工具面板可以接收键盘却不作为 main window。
    override var canBecomeMain: Bool { false }

    // 键盘事件沿 responder chain 分发；这里处理自己认识的键，其余是否交给 super 由后续分支决定。
    override func keyDown(with event: NSEvent) {
        // NSEvent.keyCode 是硬件虚拟键码，53 固定为 Escape；不要用 characters 比较，因为输入法和键盘布局会改变字符。
        guard event.keyCode == 53 else {
            super.keyDown(with: event)
            return
        }
        onEscape?()
    }

    /// AppKit 会把部分 Esc 事件沿 responder chain 转换为 cancelOperation:。
    /// 同时实现它，可以覆盖 TextField 正在编辑等不会直接进入 keyDown 的场景。
    override func cancelOperation(_ sender: Any?) {
        // responder chain 从当前 First Responder 向父 View、Window 逐级寻找 cancelOperation:；
        // 这是 AppKit 的命令路由机制，类似浏览器事件冒泡但由对象链决定。
        onEscape?()
    }

    override func close() {
        onEscape = nil
        super.close()
    }
}

/// NSHostingView 默认可能把非 key 窗口的第一次点击仅用于激活窗口。
/// 截图画布需要第一次按下就开始绘制，因此明确接受 first mouse；同时由闭包提供
/// 当前工具对应的 NSCursor，把 SwiftUI 绘图内容与 AppKit 光标管理隔离开。
@MainActor
final class EditorFirstMouseHostingView<Content: View>: NSHostingView<Content> {
    private let cursorSession: ScreenshotCursorSession?
    private let cursorContext: (CGPoint) -> ScreenshotCursorContext
    private let defaultCursorContext: () -> ScreenshotCursorContext
    private var cursorRegion: ScreenshotCursorRegion?
    private var cursorTrackingArea: NSTrackingArea?

    /// NSHostingView 把 init(rootView:) 声明为 required designated initializer。
    /// 这是 Swift 特有的构造约束，Java 没有 required 构造器：即使我们增加了带
    /// cursorContext 的初始化器，也必须保留这个签名。默认策略使用系统箭头。
    required init(rootView: Content) {
        cursorSession = nil
        cursorContext = { _ in .outside }
        defaultCursorContext = { .outside }
        super.init(rootView: rootView)
    }

    init(
        rootView: Content,
        cursorSession: ScreenshotCursorSession,
        cursorContext: @escaping (CGPoint) -> ScreenshotCursorContext,
        defaultCursorContext: @escaping () -> ScreenshotCursorContext = { .outside }
    ) {
        self.cursorSession = cursorSession
        self.cursorContext = cursorContext
        self.defaultCursorContext = defaultCursorContext
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    // NSCoder 初始化用于 Storyboard/XIB 解档；本类型仅支持代码创建，下面明确拒绝解档构造路径。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    
    // 控制非 key 窗口的第一击是否直接触发控件；返回 true 可避免必须先激活再点第二次。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // AppKit 重建鼠标区域时调用；注册 cursor rect 比只执行一次 NSCursor.set 更适合持续显示指定光标。
    override func resetCursorRects() {
        // AppKit 可以在窗口显示前重建光标区域，这里只校验会话和视图状态。
        guard cursorRegion?.isCurrentSession == true, !isHiddenOrHasHiddenAncestor else { return }
        super.resetCursorRects()
        let point = window.map { convert($0.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil) } ?? .zero
        let context = bounds.contains(point) ? cursorContext(point) : defaultCursorContext()
        addCursorRect(bounds, cursor: ScreenshotCursorPolicy.cursor(for: context))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cursorRegion = window == nil ? nil : cursorSession?.register(view: self, context: cursorContext)
    }

    // NSTrackingArea 订阅进入、离开和移动；尺寸变化后应重建区域，避免仍用旧 bounds 做命中。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        // NSTrackingArea 告诉 AppKit 哪个矩形需要持续产生进入、离开、移动和 cursorUpdate 回调；
        // `.inVisibleRect` 令它随裁剪/尺寸自动匹配可见部分，避免窗口调整后使用旧 rect。
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        // 光标不属于 SwiftUI View 的状态树，必须经 AppKit 回调调用 NSCursor.set()；region 内部完成该操作。
        cursorRegion?.refresh()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        cursorRegion?.refresh()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        cursorRegion?.refresh()
    }

    /// 工具切换发生在独立工具栏窗口中，鼠标可能尚未移动，所以不能只等待
    /// AppKit 下一次 cursorUpdate；主动设置后，用户选择工具时立刻看到正确光标。
    func refreshCursor() {
        guard cursorRegion?.isCurrentSession == true else { return }
        // 要求 AppKit 重新询问指定 View 的 cursor rect；用于工具切换后鼠标未移动的情况。
        window?.invalidateCursorRects(for: self)
        cursorRegion?.refresh(afterTransition: true)
    }
}
