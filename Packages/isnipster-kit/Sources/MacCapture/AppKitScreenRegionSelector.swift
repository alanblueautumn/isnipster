import MacShared
import MacScreenshotSupport
// 阅读路线
// Selector 管等待用户选择的异步会话，SelectionOverlayView 管鼠标动作，Coordinator 管窗口交接。
// continuation 把回调转换成 await；确认、取消、创建失败都必须恰好完成一次等待。
// 官方参考（CheckedContinuation 桥接回调）：https://developer.apple.com/documentation/swift/checkedcontinuation

import AppKit
import CaptureFeature
import ColorPickerFeature
import QuartzCore
import SwiftUI
import iSnipsterCore

/// 定义截图选择和编辑阶段共享的遮罩视觉参数。
/// 如果两处各写一个透明度，即使只差 0.04，面板交接时也会表现为整屏闪烁。
enum ScreenshotOverlayAppearance {
    static let dimmingAlpha: CGFloat = 0.34
}

/// 冻结屏幕上的截图选区实现。
///
/// 快捷键触发时只截取鼠标所在显示器，其他显示器只显示不可交互的遮罩；这样既避免
/// 多屏完整位图带来的内存翻倍，也让一次 ScreenSelection 永远对应一张 FrozenScreenFrame。
///
/// Java 阅读提示：NSPanel/NSView 属于传统 AppKit，类似 Swing Window/Component；
/// 它们必须在主线程使用，所以整个 selector 标记为 `@MainActor`。
@MainActor
public final class AppKitScreenRegionSelector: ScreenRegionSelecting {
    private let overlayCoordinator: ScreenshotOverlayCoordinator
    private let cursorController: ScreenshotCursorController
    private let copyColor: @MainActor (String) -> Bool
    private var panels: [SelectionPanel] = []
    private var continuation: CheckedContinuation<ScreenSelection, Error>?
    /// Esc/Enter 不能只依赖某个 NSView 恰好拥有 First Responder。这个本地监听器覆盖
    /// 当前应用收到的键盘事件，并在截图结束的每条路径中对称移除。
    private var escapeMonitor: Any?
    private var cursorSession: ScreenshotCursorSession?

    public init(
        overlayCoordinator: ScreenshotOverlayCoordinator,
        cursorController: ScreenshotCursorController,
        copyColor: @escaping @MainActor (String) -> Bool
    ) {
        self.overlayCoordinator = overlayCoordinator
        self.cursorController = cursorController
        self.copyColor = copyColor
    }

    public func ensureScreenCapturePermission() throws {
        try ScreenCapturePermission.requireAccess()
    }

    /// 取鼠标所在屏幕的 ID、两套全局矩形和缩放倍率；未命中时退到系统主窗口所在屏幕。
    public func currentCaptureTarget() throws -> ScreenCaptureTarget {
        // NSEvent.mouseLocation 是 AppKit 全局“点”坐标，原点在主屏左下；它不是某个 View 的局部坐标。
        let mouseLocation = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
                ?? NSScreen.main,
              let displayID = Self.displayID(for: screen) else {
            throw AppFailure.unavailable(AppText.text("无法确定鼠标所在显示器"))
        }

        return ScreenCaptureTarget(
            displayID: displayID,
            // ScreenCaptureKit/Quartz 使用左上原点的全局显示器坐标。
            // CGDisplayBounds 来自 Quartz/CoreGraphics，返回物理显示器的捕获空间；`CGDirectDisplayID` 是 C 风格的显示器句柄。
            rectInCaptureSpace: CGDisplayBounds(CGDirectDisplayID(displayID)),
            // AppKit Panel 使用左下原点的全局坐标，两者不能混用。
            globalRect: screen.frame,
            // backingScaleFactor 相当于前端 devicePixelRatio：布局仍以 point 计，位图按该倍数拥有像素。
            displayScale: screen.backingScaleFactor
        )
    }

    /// 挂起等待选区结果；面板与 continuation 已存在时拒绝第二次会话，防止覆盖尚未完成的等待者。
    public func selectRegion(in frozenFrame: FrozenScreenFrame) async throws -> ScreenSelection {
        guard continuation == nil,
              panels.isEmpty,
              !overlayCoordinator.hasStagedPanels else {
            throw AppFailure.unavailable(AppText.text("已有截图操作正在进行"))
        }

        // 公开协议允许单独使用 selector，因此这里仍做一次成本极低的兜底检查。
        try ensureScreenCapturePermission()
        cursorSession = cursorController.beginSelection()

        // AppKit 鼠标事件是 callback 风格，而上层希望顺序书写 async/await。
        // CheckedContinuation 类似把 CompletableFuture 的 complete/completeExceptionally
        // 暴露出来：后面的 complete/cancel 必须且只能 resume 一次。
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            installEscapeMonitor()
            presentPanels(frozenFrame: frozenFrame)
        }
    }

    /// 有等待者时以取消错误恢复；没有等待者时仍清理残留窗口。
    public func cancelSelection() {
        if continuation != nil {
            cancel()
        } else {
            // continuation 已经异常丢失时仍以“先解锁桌面”为最高优先级。
            dismissSelectionOverlay()
        }
    }

    /// 清理选择器和协调器仍持有的资源；已交给编辑器的面板由编辑器负责结束。
    public func dismissSelectionOverlay() {
        removeEscapeMonitor()
        closePanels()
        // 捕获失败时编辑器没有机会接管，待交接面板仍由协调器持有，必须一并关闭。
        overlayCoordinator.discardStagedPanels()
        endCursorSession()
    }

    private func presentPanels(frozenFrame: FrozenScreenFrame) {
        guard let cursorSession, cursorSession.isCurrent else {
            cancel()
            return
        }
        // 截图选区不能激活 iSnipster。激活应用会让鼠标下方原本的 Key Window 失焦，
        // macOS 随即重绘其标题栏、强调色和材质；用户立刻拖动时，这次重绘看起来
        // 就像目标窗口闪了一下。SelectionPanel 使用 nonactivatingPanel，仍可接收事件。
        let windowSnapshot = AppKitWindowSnapshot.capture()

        // 每块物理屏幕仍创建一个无边框 Panel，防止截图期间鼠标点击穿透到其他屏幕。
        // 只有目标屏幕显示冻结图片并允许选择；其他屏幕只负责遮罩和点击取消。
        panels = NSScreen.screens.map { screen in
            // 每次会话使用新的 Panel，避免上一轮 key/鼠标穿透状态污染本次输入。
            let panel = overlayCoordinator.checkoutSelectionPanel(for: screen, cursorSession: cursorSession)
            let screenID = Self.displayID(for: screen)
            let isCaptureScreen = screenID == frozenFrame.target.displayID
            panel.selectionView.prepareForCapture(
                frozenImage: isCaptureScreen ? frozenFrame.image.cgImage : nil,
                windowSnapshot: isCaptureScreen ? windowSnapshot : .empty,
                isInteractionEnabled: isCaptureScreen
            )
            panel.selectionView.onCopyColor = copyColor
            // View 通过闭包把事件上抛给控制器。使用 weak 避免
            // selector -> panels -> view -> closure -> selector 的强引用环。
            // 这里只弱引用 selector，screen 必须强引用。
            // NSScreen.screens 返回的 NSScreen 对象不保证由当前数组之外长期持有；如果也
            // weak 捕获，用户稍后松开鼠标时 screen 可能已经变成 nil，闭包会静默退出，
            // 对应上层的 selectRegion continuation 永远得不到 resume。
            // Java 对照：不能把完成异步请求所必需的上下文只放进 WeakReference。
            if isCaptureScreen {
                panel.selectionView.onComplete = { [weak self, screen] rect, windowID in
                    guard let self else { return }
                    self.complete(
                        rectInScreenView: rect,
                        windowID: windowID,
                        screen: screen
                    )
                }
            }
            panel.selectionView.onCancel = { [weak self] in
                self?.cancel()
            }
            // 冻结图、遮罩路径和首个窗口候选都在 Panel 不可见时准备好。
            // orderFront 后 WindowServer 收到的第一帧就是完整画面，不会先透明再补内容。
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()
            // 把窗口放到前面显示，不等于激活整个应用或把某个输入控件设为 first responder。
            panel.orderFrontRegardless()
            return panel
        }

        // 多屏时“数组第一项”不一定是鼠标所在屏幕。把当前鼠标所在 Panel 设为 key，
        // 可以保证截图刚出现后的第一次按下、拖动和 Escape 都由正确的窗口接收。
        // Java 对照：类似把焦点显式 requestFocus 到鼠标所在的顶层 Window。
        // 不再通过 NSWindow.screen 反推显示器：窗口刚 orderFront 时该属性偶尔仍为 nil。
        // SelectionPanel 在初始化时已经保存稳定 displayID，直接匹配不会选错输入窗口。
        guard let interactionPanel = panels.first(where: {
            $0.displayID == frozenFrame.target.displayID
        }) else {
            finish(.failure(AppFailure.unavailable(AppText.text("无法创建截图交互窗口"))))
            return
        }
        interactionPanel.makeKeyAndOrderFront(nil)
        // first responder 是窗口内接收键盘的对象，类似输入焦点；先让窗口可接收键盘，再选择具体控件。
        interactionPanel.makeFirstResponder(interactionPanel.selectionView)
        // 同步和下一显示周期的刷新都由管理器执行，结束会话时统一取消。
        interactionPanel.selectionView.activateWindowSelectionCursor()
    }

    /// 从 NSScreen 的设备字典读取数值句柄，用来和 CoreGraphics/ScreenCaptureKit 的显示器匹配。
    private static func displayID(for screen: NSScreen?) -> CGDirectDisplayID? {
        guard let number = screen?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber else {
            return nil
        }
        return number.uint32Value
    }

    /// 把局部选框转换为业务 DTO，转交仍显示的面板，再恢复上层 await；此处不再请求系统像素。
    private func complete(
        rectInScreenView rect: CGRect,
        windowID: CGWindowID?,
        screen: NSScreen
    ) {
        guard continuation != nil else { return }
        guard let cursorSession, cursorSession.isCurrent else {
            cancel()
            return
        }
        // 保留选择视图已经确定的边界；这里再按整数 pt 向外取整会扩大 Retina 选区。
        let standardized = rect.standardized
        guard standardized.width >= 2, standardized.height >= 2 else {
            cancel()
            return
        }

        guard let displayID = Self.displayID(for: screen) else {
            finish(.failure(AppFailure.operationFailed(AppText.text("无法取得显示器标识"))))
            return
        }

        // SelectionOverlayView 与 AppKit 一样以左下角为原点；ScreenCaptureKit 的
        // display sourceRect 使用左上角为原点，因此在这里完成唯一一次 Y 轴翻转。
        let topLeftRect = CGRect(
            x: standardized.minX,
            y: screen.frame.height - standardized.maxY,
            width: standardized.width,
            height: standardized.height
        )

        let selection = ScreenSelection(
            displayID: displayID,
            windowID: windowID,
            rectInDisplay: topLeftRect,
            displayScale: screen.backingScaleFactor,
            globalRect: standardized.offsetBy(
                dx: screen.frame.minX,
                dy: screen.frame.minY
            )
        )

        // 不在鼠标松开时关闭面板。系统截图早在遮罩出现前已经完成，后面只是内存裁剪；
        // 编辑器会接管同一批 NSPanel，避免“关闭选区窗口 + 创建编辑窗口”的非原子交接。
        let pending = continuation
        continuation = nil
        removeEscapeMonitor()
        let handoffPanels = panels
        panels.removeAll(keepingCapacity: false)
        // 控制整个窗口是否接收鼠标；设为 true 时事件可落到下层窗口，不能把它当作阻止点击穿透。
        handoffPanels.forEach { $0.ignoresMouseEvents = true }
        overlayCoordinator.stageSelectionPanels(handoffPanels, cursorSession: cursorSession)
        self.cursorSession = nil
        pending?.resume(returning: selection)
    }

    private func cancel() {
        finish(.failure(AppFailure.cancelled))
    }

    /// Result 类似成功/失败联合类型；先取走 continuation，再 resume，避免事件重入时重复完成。
    private func finish(_ result: Result<ScreenSelection, Error>) {
        let pending = continuation
        continuation = nil
        removeEscapeMonitor()
        closePanels()
        endCursorSession()
        pending?.resume(with: result)
    }

    /// 只结束本选择器拥有的光标会话，防止过期清理影响后来开始的截图。
    private func endCursorSession() {
        cursorSession?.end()
        cursorSession = nil
    }

    private func closePanels() {
        // 先 orderOut 并清空冻结图，再关闭窗口；即使异常退出也不保留全屏输入面板。
        overlayCoordinator.recycleSelectionPanels(panels)
        panels.removeAll(keepingCapacity: false)
    }

    private func installEscapeMonitor() {
        removeEscapeMonitor()
        // 本地 monitor 只观察本应用将要分派的事件；返回 nil 表示消费事件，返回 event 才继续交给 responder chain。
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {
                self.cancel()
                return nil
            }
            if event.keyCode == 8, event.modifierFlags.contains(.command) {
                // keyCode 8 是物理键 C。截图 Panel 是 nonactivatingPanel，不能依赖某个
                // View 始终持有键盘焦点，因此在会话级监听器统一处理 Cmd+C。
                // 只有目标显示器上的选区 View 真正复制成功时才吞掉事件；这和 Java
                // AWT 中在顶层 KeyEventDispatcher 先处理全局快捷键的思路相近。
                let currentPanels = self.panels
                for panel in currentPanels where panel.selectionView.copyCurrentColor() {
                    return nil
                }
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                // 复制数组后再回调确认，因为确认会同步把 self.panels 转移给编辑器。
                // Java 对照：避免遍历集合的同时由回调修改原集合。
                let currentPanels = self.panels
                for panel in currentPanels where panel.selectionView.confirmSelectionIfReady() {
                    return nil
                }
            }
            return event
        }
    }

    /// 移除监听并清空 token，允许下次会话重新注册；仅置 nil 不会替系统注销监听。
    private func removeEscapeMonitor() {
        guard let escapeMonitor else { return }
        NSEvent.removeMonitor(escapeMonitor)
        self.escapeMonitor = nil
    }
}
