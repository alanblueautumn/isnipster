import MacShared
import MacPreferences
// 阅读路线
// 管理底部历史窗口、进退场动画、原应用恢复和自动粘贴；历史内容由 Controller 管。
// 先写系统剪贴板，再切回目标应用并尝试 Cmd+V；事件发送成功不等于目标文本框已接受内容。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import ClipboardFeature
import Combine
import ImageIO
import Quartz
import QuartzCore
import SwiftUI
import iSnipsterCore

// 样式导航：ClipboardShelfMetrics 管整体缩放，shelfFrame 管桌面位置，卡片 View 管内容和圆角。
// SwiftUI 的 @State 类似组件本地 ref；controller 类似共享 store；Combine bridge 把原生键盘事件送进 View。

/// Paste 风格的剪贴板时间线窗口。窗口只负责展示和交互，历史数据由
/// ClipboardController/ClipboardHistoryStore 管理并持久化到本机应用支持目录。
@MainActor
public final class ClipboardWindowPresenter: NSObject, ClipboardPastePresentation {

    private let controller: ClipboardController
    private let focus = ClipboardFocusCoordinator()
    private let keyboardBridge = ClipboardKeyboardBridge()
    private let quickLookController = ClipboardQuickLookController()
    private var panel: NSPanel?
    private var outsideClickMonitor: Any?
    private var isDismissalSuspendedForCapture = false
    private var isDismissing = false
    private var presentedFrame: NSRect?
    private weak var slidingContentView: NSView?
    private var animationGeneration = 0
    private let pasteCoordinator: ClipboardPasteCoordinator
    private var pastePermissionWindowController: DirectPastePermissionWindowController?
    private var isPresentingPastePermissionPrompt: Bool { pastePermissionWindowController != nil }
    public var onPasteFailed: (@MainActor (Error) -> Void)?

    public init(controller: ClipboardController, clipboardWriter: any ClipboardWriting, client: any PasteboardClient) {
        self.pasteCoordinator = ClipboardPasteCoordinator(controller: controller, writer: clipboardWriter, client: client)
        self.controller = controller
        super.init()
        pasteCoordinator.presentation = self
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange(_:)),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    @objc
    private func applicationDidActivate(_ notification: Notification) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                as? NSRunningApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }
        focus.recordActivation(application)
        if panel?.isVisible == true,
           !isDismissing,
           !isPresentingPastePermissionPrompt,
           !isDismissalSuspendedForCapture {
            // 用户通过 Mission Control、触控板或应用切换进入了另一个窗口。
            // 此时直接取消剪贴板架，不能再把焦点送回原应用。
            dismissImmediately(restorePreviousApplication: false)
        }
    }

    @objc
    private func activeSpaceDidChange(_ notification: Notification) {
        guard panel?.isVisible == true,
              !isPresentingPastePermissionPrompt,
              !isDismissalSuspendedForCapture else { return }
        // canJoinAllSpaces 会让高层级面板跟随到新空间，因此空间切换完成时主动取消。
        dismissImmediately(restorePreviousApplication: false)
    }

    public func toggle() {
        if let pastePermissionWindowController {
            pastePermissionWindowController.show(above: panel?.frame, on: targetScreen())
            return
        }
        if let panel, panel.isVisible {
            dismissAndRestorePreviousApplication()
            return
        }

        controller.scheduleMaintenance()
        focus.remember(excluding: panel)
        controller.query = ""
        if panel == nil {
            preparePanel()
        }
        guard let panel, let slidingContentView else { return }
        isDismissing = false
        animationGeneration += 1

        let presentedFrame = shelfFrame()
        self.presentedFrame = presentedFrame

        panel.setFrame(presentedFrame, display: false)
        preparePresentationAnimation(for: slidingContentView)

        // 剪贴板架使用 nonactivatingPanel：它可以成为 key window 接收搜索和点击，
        // 但不会抢走原应用的前台激活状态与文本 first responder。
        panel.orderFrontRegardless()
        panel.makeKey()
        CATransaction.flush()
        installOutsideClickMonitor()
    }

    /// 截图期间保留当前剪切板面板，并暂停把截图选区点击误判为面板外部点击。
    public func suspendDismissalForCapture() {
        quickLookController.close()
        pasteCoordinator.cancel()
        guard panel?.isVisible == true || isPresentingPastePermissionPrompt else { return }
        isDismissalSuspendedForCapture = true
        pastePermissionWindowController?.suspendForCapture()
        removeOutsideClickMonitor()
    }

    /// 截图流程结束后恢复面板原有的点击外部收起行为。
    public func resumeDismissalAfterCapture() {
        guard isDismissalSuspendedForCapture else { return }
        isDismissalSuspendedForCapture = false
        pastePermissionWindowController?.resumeAfterCapture()
        guard panel?.isVisible == true else { return }
        installOutsideClickMonitor()
    }

    private func preparePanel() {
        let root = ClipboardHistoryView(
            controller: controller,
            keyboardBridge: keyboardBridge,
            onPaste: { [weak self] entry, asPlainText in
                self?.paste(entry, asPlainText: asPlainText)
            },
            onCopy: { [weak self] entry, asPlainText in
                guard let self else { return }
                quickLookController.close()
                closePastePermissionPrompt()
                installOutsideClickMonitor()
                guard !isDismissing, !isDismissalSuspendedForCapture else { return }
                pasteCoordinator.copy(entry, asPlainText: asPlainText)
            },
            onOpenURL: { [weak self] url in
                self?.openInDefaultBrowser(url)
            },
            onPreview: { [weak self] entry in
                guard let self, let panel, panel.isVisible else { return }
                do {
                    try quickLookController.toggle(entry, from: panel)
                } catch {
                    AppDiagnostics.failure(error, stage: "clipboard.preview", requestID: entry.id)
                    onPasteFailed?(error)
                }
            },
            onDelete: { [weak self] entry in
                guard let self else { return }
                if quickLookController.previewedEntryID == entry.id { quickLookController.close() }
                controller.remove(entry)
            },
            onClose: { [weak self] in self?.dismissAndRestorePreviousApplication() }
        )
        let frame = shelfFrame()
        let panel = makePanel(rootView: root, frame: frame, keyboardBridge: keyboardBridge)
        self.panel = panel
        presentedFrame = frame
    }

    /// 桌面架的绝对定位。frame 是全屏矩形，horizontalInset/bottomInset 控制两侧与底部留白。
    private func shelfFrame() -> NSRect {
        let screenFrame = targetScreen().frame
        let horizontalInset: CGFloat = 10
        let bottomInset: CGFloat = 4
        let height = ClipboardShelfMetrics.scaled(min(300, max(278, screenFrame.height * 0.25)))
        return NSRect(
            x: screenFrame.minX + horizontalInset,
            y: screenFrame.minY + bottomInset,
            width: screenFrame.width - horizontalInset * 2,
            height: height
        )
    }

    /// Core Animation 区分 model layer 与 presentation layer；先把最终状态写入 model，
    /// 再添加从起点到终点的动画，避免动画结束后视图跳回旧位置。
    private func preparePresentationAnimation(for view: NSView) {
        guard let layer = view.layer else { return }
        layer.removeAllAnimations()

        CATransaction.begin()
        // 关闭本次图层属性修改的隐式动画，让边框/遮罩直接跟随鼠标，而不是缓慢补间到新位置。
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()

        // 显式动画只描述 presentation layer 的过渡；最终属性仍要写回 model layer，否则结束后可能跳回。
        let translation = CABasicAnimation(keyPath: "transform.translation.y")
        translation.fromValue = -52
        translation.toValue = 0

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0.88
        opacity.toValue = 1

        let animation = CAAnimationGroup()
        animation.animations = [translation, opacity]
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.16, 1.0, 0.30, 1.0
        )
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: "clipboardShelf.present")
    }

    private func paste(_ entry: ClipboardEntry, asPlainText: Bool) {
        guard !isDismissing, !isDismissalSuspendedForCapture else { return }
        quickLookController.close()
        pasteCoordinator.paste(entry, asPlainText: asPlainText, target: focus.target)
    }

    func dismissForPaste(completion: @escaping @MainActor () -> Void) {
        _ = focus.takeTarget()
        dismissPanel(completion: completion)
    }

    func showPastePermission(destinationName: String?, response: @escaping @MainActor (ClipboardPastePermissionResponse) -> Void) {
        closePastePermissionPrompt()
        removeOutsideClickMonitor()
        let prompt = DirectPastePermissionWindowController(destinationName: destinationName) { [weak self] result in
            guard let self else { return }
            pastePermissionWindowController = nil
            response(result)
        }
        pastePermissionWindowController = prompt
        if isDismissalSuspendedForCapture { prompt.suspendForCapture() }
        prompt.show(above: panel?.isVisible == true ? panel?.frame : nil, on: targetScreen())
    }

    func resumeAfterPastePrompt() {
        guard !isDismissalSuspendedForCapture, panel?.isVisible == true else { return }
        panel?.makeKey()
        installOutsideClickMonitor()
    }

    func pasteFailed(_ error: Error) { onPasteFailed?(error) }

    /// 关闭并释放授权提示控制器，避免下一次面板显示复用旧回调。
    func closePastePermissionPrompt() {
        let prompt = pastePermissionWindowController
        pastePermissionWindowController = nil
        prompt?.closeWithoutResponse()
    }

    /// 退出历史面板后交还前台控制权；恢复目标应用不是重新写入剪贴板。
    private func dismissAndRestorePreviousApplication() {
        pasteCoordinator.cancel()
        let target = focus.takeTarget()
        dismissPanel { target.restore() }
    }

    /// 让 NSWorkspace 使用系统默认处理程序打开 URL，再结束当前面板交互。
    private func openInDefaultBrowser(_ url: URL) {
        pasteCoordinator.cancel()
        // 打开链接后目标变成默认浏览器，不再恢复弹出面板前的应用。
        focus.clearApplication()
        dismissPanel {
            // 交给 macOS 选择 URL 对应的处理程序；可以打开网页或系统设置深链，不是应用内 HTTP 请求。
            _ = NSWorkspace.shared.open(url)
        }
    }

    /// 进入截图、取色或其他顶层模式前同步隐藏，避免退场动画被截进画面。
    public func dismissImmediately(restorePreviousApplication: Bool = true) {
        quickLookController.close()
        pasteCoordinator.cancel()
        closePastePermissionPrompt()
        removeOutsideClickMonitor()
        isDismissalSuspendedForCapture = false
        animationGeneration += 1
        // orderOut 只把窗口移出屏幕，不销毁对象；若还持有 contentView 或控制器，相关资源仍然存在。
        panel?.orderOut(nil)
        resetPresentationLayer()
        isDismissing = false
        let target = focus.takeTarget()
        if restorePreviousApplication { target.restore() }
    }

    /// 执行退出动画并在结束时调用 completion；隐藏窗口与业务后续操作通过回调排序。
    private func dismissPanel(completion: @escaping @MainActor () -> Void) {
        quickLookController.close()
        closePastePermissionPrompt()
        guard !isDismissing else { return }
        focus.clearLocal()
        removeOutsideClickMonitor()
        guard let panel, panel.isVisible else {
            completion()
            return
        }

        isDismissing = true
        guard let slidingContentView else {
            panel.orderOut(nil)
            isDismissing = false
            completion()
            return
        }
        guard let layer = slidingContentView.layer else {
            panel.orderOut(nil)
            isDismissing = false
            completion()
            return
        }

        animationGeneration += 1
        let generation = animationGeneration
        let currentTranslation = (layer.presentation()?
            .value(forKeyPath: "transform.translation.y") as? NSNumber)?.doubleValue ?? 0

        // 液态玻璃整体透明度变化会触发大面积离屏合成。只做位移，并让内容
        // 完整越过窗口下边界之后再 orderOut，避免仍有大部分可见时突然消失。
        let dismissalDistance = (presentedFrame ?? panel.frame).height + 8
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = currentTranslation
        animation.toValue = -dismissalDistance
        animation.duration = 0.16
        animation.timingFunction = CAMediaTimingFunction(
            controlPoints: 0.33, 0.0, 0.67, 1.0
        )
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false

        let finish: @MainActor () -> Void = { [weak self, weak panel, weak slidingContentView] in
            guard let self,
                  self.panel === panel,
                  self.isDismissing,
                  self.animationGeneration == generation else { return }
            slidingContentView?.layer?.removeAllAnimations()
            panel?.orderOut(nil)
            self.isDismissing = false
            completion()
        }

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            if Thread.isMainThread {
                // 这是断言当前已经处于 MainActor 的入口，不会调度到主线程；前面的执行上下文保证不可省略。
                MainActor.assumeIsolated {
                    finish()
                }
            } else {
                // 把闭包排到主队列稍后执行；常用于等待当前布局/焦点切换结束，不会创建后台工作线程。
                DispatchQueue.main.async {
                    finish()
                }
            }
        }
        layer.add(animation, forKey: "clipboardShelf.dismiss")
        CATransaction.commit()
        CATransaction.flush()
    }

    /// 清理动画留下的展示状态，让下一次显示从确定的 model 状态开始。
    private func resetPresentationLayer() {
        guard let layer = slidingContentView?.layer else { return }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DIdentity
        layer.opacity = 1
        CATransaction.commit()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        guard !isPresentingPastePermissionPrompt, !isDismissalSuspendedForCapture else { return }
        let callback = OutsideClickCallback { [weak self] in
            guard let self, panel?.isVisible == true, !isDismissing,
                  !isPresentingPastePermissionPrompt, !isDismissalSuspendedForCapture else { return }
            // nonactivatingPanel 的首次点击在极短的窗口切换阶段仍可能被全局
            // monitor 观察到。用屏幕坐标明确排除面板自身，不能把面板内留白
            // 或卡片首击误判成外部点击。
            guard let panel, !panel.frame.contains(NSEvent.mouseLocation) else { return }
            guard !quickLookController.contains(NSEvent.mouseLocation) else { return }
            // 外部点击通常意味着用户正在切换窗口。同步 orderOut，避免退场动画
            // 覆盖到新窗口上形成一帧闪烁。
            dismissImmediately(restorePreviousApplication: false)
        }
        // global monitor 观察其他应用的匹配事件，不能拦截或改写事件；结束监听时须移除返回的 token。
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            callback.invoke()
        }
    }

    /// 移除外部点击监听；截图暂停自动收起或窗口关闭后不应继续响应旧监听。
    private func removeOutsideClickMonitor() {
        guard let outsideClickMonitor else { return }
        NSEvent.removeMonitor(outsideClickMonitor)
        self.outsideClickMonitor = nil
    }

    private func makePanel(
        rootView: ClipboardHistoryView,
        frame presentedFrame: NSRect,
        keyboardBridge: ClipboardKeyboardBridge
    ) -> NSPanel {
        let panel = BottomShelfPanel(
            contentRect: presentedFrame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = AppText.text("剪贴板历史")
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        // 允许面板仅在控件需要键盘时取得 key；按钮点击与输入框输入不一定需要相同的焦点策略。
        panel.becomesKeyOnlyIfNeeded = false
        // 决定应用失去激活状态时是否自动隐藏面板；隐藏不等于关闭，也不会自动释放会话状态。
        panel.hidesOnDeactivate = false
        // 指定系统对窗口显示/隐藏采用的动画行为；与内容图层 CABasicAnimation 是不同层面的动画。
        panel.animationBehavior = .none
        // screenSaver 层级直接覆盖 Dock，不改变系统的 Dock 显示状态，因此不会触发 Dock 收起动画。
        panel.level = .screenSaver
        // 只在弹出时移动到当前空间，不能加入所有空间；否则空间切换过程中面板
        // 会先出现在目标空间，再收到 activeSpaceDidChange 通知，造成闪烁。
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: 620, height: ClipboardShelfMetrics.scaled(278))
        // 外层窗口保持透明，实色背景随内容一起从屏幕下方进入。
        panel.backgroundColor = .clear
        // isOpaque 是给合成器的“不透明”声明，不是设置颜色；透明窗口还要使用透明 backgroundColor。
        panel.isOpaque = false
        // 使用系统窗口阴影，在内容裁剪范围之外突出面板与桌面的边界。
        panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if quickLookController.isVisible {
                quickLookController.close(restoreFocus: true)
            } else {
                dismissAndRestorePreviousApplication()
            }
        }
        panel.onPreviewSelection = { [weak keyboardBridge] in
            keyboardBridge?.previewSelection.send()
        }
        panel.onMoveSelection = { [weak keyboardBridge] offset in
            keyboardBridge?.moveSelection.send(offset)
        }
        panel.onPasteSelection = { [weak keyboardBridge] asPlainText in
            keyboardBridge?.pasteSelection.send(asPlainText)
        }
        panel.onPasteIndex = { [weak keyboardBridge] index in
            keyboardBridge?.pasteIndex.send(index)
        }
        panel.onFocusSearch = { [weak keyboardBridge] in
            keyboardBridge?.focusSearch.send()
        }

        // 普通 NSHostingView 会把非活动窗口收到的第一次点击只用于激活窗口，
        // Button 的动作要到第二次点击才执行。明确接受 first mouse，让第一次
        // mouseDown 同时完成窗口激活和卡片点击。
        let hostingView = FirstMouseHostingView(rootView: rootView)
        // 禁止 SwiftUI 的 intrinsic/min/max size 反向调整外层窗口；外层尺寸完全由
        // presentedFrame 控制，确保窗口始终贴在屏幕底边而不是被系统居中。
        hostingView.sizingOptions = []
        // 让 NSView 使用 backing layer，后续才能设置 CALayer 的圆角、内容与路径；视图和图层仍是两套对象。
        hostingView.wantsLayer = true
        hostingView.frame = NSRect(origin: .zero, size: presentedFrame.size)
        // AppKit 旧式自动尺寸规则，按父视图尺寸变化伸缩；不是 SwiftUI 的状态属性，也不是完整 Auto Layout 约束。
        hostingView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]

        let clippingView = NSView(frame: NSRect(origin: .zero, size: presentedFrame.size))
        clippingView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        clippingView.wantsLayer = true
        // 裁掉超出图层边界的内容；若阴影画在同一层，也可能被一起裁掉。
        clippingView.layer?.masksToBounds = true
        // NSScrollView 是 AppKit 视图，SwiftUI 外层的圆角背景不会自动裁剪它。
        // 在承载整个面板的 AppKit 容器上应用同一圆角，横向滚动时卡片就不会
        // 穿出左右两侧（尤其是底部）的圆角边界。
        clippingView.layer?.cornerRadius = 28
        clippingView.layer?.cornerCurve = .continuous
        clippingView.addSubview(hostingView)

        panel.contentView = clippingView
        slidingContentView = hostingView
        panel.setFrame(presentedFrame, display: false)
        return panel
    }

    private func targetScreen() -> NSScreen {
        // screens 的第一项是包含系统主菜单栏的主显示器，其原点是 AppKit 桌面坐标系的基准。
        // 不再跟随鼠标，否则多显示器纵向错位时会把面板放到主屏中部。
        NSScreen.screens.first ?? NSScreen.main!
    }
}

/// NSEvent 的全局监听回调可能来自非主线程。盒子只负责把无参数动作投递回 MainActor，
/// 不把 NSEvent 或窗口对象跨线程传递。
private final class OutsideClickCallback: @unchecked Sendable {
    private let action: @MainActor () -> Void

    init(action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func invoke() {
        DispatchQueue.main.async { [self] in
            action()
        }
    }
}

