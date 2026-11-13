import MacShared
import MacScreenshotSupport
// 阅读路线
// 选区主状态机：准备冻结图 → 悬停选窗/拖选 → 确认 → 调整或被动遮罩 → 释放。
// 绘制、几何和取色扩展与状态放在同一文件，内部状态保持 private；外部只能调用会话操作。
// 官方参考（NSView 事件与绘制）：https://developer.apple.com/documentation/appkit/nsview

import AppKit
import CaptureFeature
import ColorPickerFeature
import QuartzCore
import SwiftUI
import iSnipsterCore

/// 实现窗口命中、矩形选择、移动缩放、像素取色和选区反馈的核心遮罩视图。
@MainActor
final class SelectionOverlayView: NSView {
    /// 四条边可以组合，组合后自然表达左上、右下等四个角点。
    /// Java 对照：OptionSet 类似 bit mask enum，但 Swift 可以用 contains 做类型安全判断。
    private struct ResizeEdges: OptionSet, Sendable {
        let rawValue: UInt8

        static let left = ResizeEdges(rawValue: 1 << 0)
        static let right = ResizeEdges(rawValue: 1 << 1)
        static let bottom = ResizeEdges(rawValue: 1 << 2)
        static let top = ResizeEdges(rawValue: 1 << 3)
    }

    /// 描述当前拖动是在移动整个选区还是缩放指定边缘。
    private enum AdjustmentMode {
        case move
        case resize(ResizeEdges)
    }

    var onComplete: ((CGRect, CGWindowID?) -> Void)?
    var onCancel: (() -> Void)?
    var onCopyColor: ((String) -> Bool)?
    /// 编辑器接管后，选区变化先实时更新窗口布局，mouseUp 再触发一次最终内存裁剪。
    var onSelectionChanged: ((CGRect) -> Void)?
    var onSelectionChangeEnded: ((CGRect) -> Void)?
    private var windowSnapshot = AppKitWindowSnapshot.empty
    private var isInteractionEnabled = false
    /// 初选使用十字星，锁定后按移动和缩放状态计算；编辑阶段由画布接管。
    /// 它与 isInteractionEnabled 分开，因为非目标屏幕虽然不能选区，也属于截图遮罩。
    private var isCaptureCursorActive = false
    private let cursorSession: ScreenshotCursorSession
    private var cursorRegion: ScreenshotCursorRegion?
    private var cursorTrackingArea: NSTrackingArea?

    private var dragStart: CGPoint?
    private var pressedWindowRect: CGRect?
    private var hoveredWindowID: CGWindowID?
    private var pressedWindowID: CGWindowID?
    private var isFreeDragging = false
    /// 第一次鼠标松开只锁定选区；锁定后才允许移动和缩放，确认时再回调上层裁剪。
    private var isSelectionLocked = false
    private var selectedWindowID: CGWindowID?
    private var adjustmentMode: AdjustmentMode?
    private var adjustmentStartRect: CGRect = .zero
    private var adjustmentDidMove = false
    private var isEditorSelectionAdjustment = false
    private var isEditingMode = false
    private var showsSelectionBorder = true
    private var selectedRect: CGRect = .zero
    /// 与 macshot 的选择语义一致：任一方向超过 5pt 才算真实拖选；
    /// 小范围鼠标抖动在 mouseUp 时仍按窗口单击处理。
    private let freeDragThreshold: CGFloat = 5
    private let minimumSelectionSide: CGFloat = 12
    /// 命中区比可见控制点更大，类似给小图标增加透明点击热区；不需要放大图标本身。
    private let resizeHitSlop: CGFloat = 7
    private let handleVisualSize: CGFloat = 6
    /// 遮罩使用一个带“偶奇填充”路径的常驻图层：外矩形负责变暗全屏，内矩形形成洞口。
    /// 拖动时只替换 path，WindowServer 会原子合成新帧，不再执行“先填黑、再 clear”的全屏重绘。
    private let frozenImageLayer = CALayer()
    private let dimmingLayer = CAShapeLayer()
    private let selectionBorderLayer = CAShapeLayer()
    private let selectionHandleLayer = CAShapeLayer()
    /// 放大镜直接读取截图开始时已经冻结的 CGImage，不启动新的系统截图请求。
    /// 这里只保留同一张图片的引用和鼠标当前颜色，不复制整屏像素。
    private var frozenImage: CGImage?
    private var currentSampledColor: SampledColor?
    private let resolutionBadge = SelectionResolutionBadge(frame: .zero)
    private let magnifierView = ScreenshotPixelMagnifierView(
        frame: CGRect(origin: .zero, size: ScreenshotPixelMagnifierView.preferredSize)
    )

    override var acceptsFirstResponder: Bool { true }

    init(frame frameRect: NSRect, cursorSession: ScreenshotCursorSession) {
        self.cursorSession = cursorSession
        super.init(frame: frameRect)
        configureOverlayLayers()
    }

    // NSCoder 初始化用于 Storyboard/XIB 解档；本类型仅支持代码创建，下面明确拒绝解档构造路径。
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 菜单栏应用的浮层可能在出现时尚未成为 key window。默认 AppKit 会把第一次点击
    /// 仅用于激活窗口；显式返回 true 后，这次点击也会继续进入 mouseDown 状态机。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cursorRegion = window == nil ? nil : cursorSession.register(view: self) { [weak self] point in
            self?.cursorContext(at: point) ?? .outside
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        // 设置图层内容的像素密度；point 布局不变，但文字/路径栅格化需要对应显示器倍率。
        frozenImageLayer.contentsScale = scale
        dimmingLayer.contentsScale = scale
        selectionBorderLayer.contentsScale = scale
        selectionHandleLayer.contentsScale = scale
        // first responder 是窗口内接收键盘的对象，类似输入焦点；先让窗口可接收键盘，再选择具体控件。
        window?.makeFirstResponder(self)
        if isInteractionEnabled {
            let location = currentMouseLocation()
            updateHoveredWindow(at: location)
            updateMagnifier(at: location)
        }
        // 要求 AppKit 重新询问指定 View 的 cursor rect；用于工具切换后鼠标未移动的情况。
        window?.invalidateCursorRects(for: self)
    }

    /// AppKit 的 cursor rect 类似 Swing Component 根据局部区域设置 Cursor。
    /// 初选阶段始终使用系统十字星；锁定后选区内部使用手形，控制点使用缩放光标。
    override func resetCursorRects() {
        guard cursorRegion?.isCurrentSession == true, !isHiddenOrHasHiddenAncestor else { return }
        super.resetCursorRects()
        guard isCaptureCursorActive else {
            addCursorRect(bounds, cursor: ScreenshotCursorPolicy.cursor(for: .outside))
            return
        }

        if adjustmentMode != nil {
            addCursorRect(bounds, cursor: ScreenshotCursorPolicy.cursor(for: cursorContext(at: currentMouseLocation())))
            return
        }

        if !isSelectionLocked {
            addCursorRect(bounds, cursor: ScreenshotCursorPolicy.cursor(for: .selecting))
            return
        }

        // 已锁定选区的外部继续使用十字星；选区内部和控制点覆盖为移动/缩放光标。
        addCursorRect(bounds, cursor: ScreenshotCursorPolicy.cursor(for: .selecting))

        guard !selectedRect.isEmpty else { return }
        // 锁定后的选区内部用于整体移动；边和角的命中区后添加，让更具体的缩放光标覆盖它。
        addCursorRect(selectedRect, cursor: ScreenshotCursorPolicy.cursor(for: .selectionInterior))
        for (center, edges) in resizeHandles(in: selectedRect) {
            let hitRect = CGRect(
                x: center.x - resizeHitSlop,
                y: center.y - resizeHitSlop,
                width: resizeHitSlop * 2,
                height: resizeHitSlop * 2
            )
            addCursorRect(hitRect, cursor: resizeCursor(for: edges))
        }
    }

    // NSTrackingArea 订阅进入、离开和移动；尺寸变化后应重建区域，避免仍用旧 bounds 做命中。
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        guard cursorRegion?.isCurrentSession == true else {
            cursorTrackingArea = nil
            return
        }
        // 注册视图的鼠标跟踪区域，选项决定订阅进入/离开/移动；它与响应者链的键盘焦点分开。
        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .cursorUpdate, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        cursorRegion?.refresh(afterTransition: true)
    }

    override func mouseExited(with event: NSEvent) {
        cursorRegion?.refresh()
    }

    override func cursorUpdate(with event: NSEvent) {
        cursorRegion?.refresh()
    }

    override func layout() {
        super.layout()
        updateOverlayLayers()
    }

    override func mouseMoved(with event: NSEvent) {
        cursorRegion?.refresh()
        guard isInteractionEnabled,
              !isEditingMode,
              !isSelectionLocked,
              dragStart == nil else { return }
        let location = convert(event.locationInWindow, from: nil)
        updateHoveredWindow(at: location)
        updateMagnifier(at: location)
    }

    // AppKit 鼠标按下回调；event.locationInWindow 属于窗口坐标，传给局部几何计算前需要转换。
    override func mouseDown(with event: NSEvent) {
        // 非目标显示器也有遮罩 Panel，用来阻止点击穿透。用户点击该屏幕时直接取消，
        // 不允许生成一个无法从当前 FrozenScreenFrame 裁剪的跨屏选区。
        guard isInteractionEnabled else {
            onCancel?()
            return
        }
        if isEditingMode {
            onCancel?()
            return
        }

        let location = convert(event.locationInWindow, from: nil)
        updateMagnifier(at: location)

        if isSelectionLocked {
            if event.clickCount >= 2, selectedRect.contains(location) {
                confirmSelection()
                return
            }

            let edges = resizeEdges(at: location)
            if !edges.isEmpty {
                beginAdjustment(.resize(edges), at: location)
                return
            }
            if selectedRect.contains(location) {
                beginAdjustment(.move, at: location)
                return
            }

            if isEditorSelectionAdjustment {
                // 工具栏已经出现后的调整态不再允许“点击外部重新框选”。
                // Java 对照：状态机已从 SELECTING 进入 ADJUSTING，非法输入应走取消，
                // 不能偷偷退回上一状态，否则窗口选区和自由选区会表现不一致。
                onCancel?()
                return
            }

            // 点击锁定选区外部表示重新选择。先恢复窗口悬停命中，再进入初选手势。
            isSelectionLocked = false
            selectedWindowID = nil
            updateHoveredWindow(at: location)
        }

        // 初选阶段先保存当前窗口候选，按下时不立即清空洞口，避免窗口“由亮变暗”闪一帧。
        // 是否属于窗口单击延迟到 mouseUp 决定：只有拖动超过阈值才切换成自由选区。
        dragStart = location
        pressedWindowRect = selectedRect.isEmpty ? nil : selectedRect
        pressedWindowID = hoveredWindowID
        isFreeDragging = false
        // mouseDown 是“窗口候选”切换为“自由选区手势”的明确边界。
        // 除了更新 cursor rect，还主动 set 一次，保证按住鼠标不移动时也立即显示十字星。
        cursorRegion?.refresh()
        window?.invalidateCursorRects(for: self)
        updateOverlayLayers()
    }

    // 拖动事件会连续到达；此阶段更新预览状态，最终确认通常放在 mouseUp，避免每帧提交业务历史。
    override func mouseDragged(with event: NSEvent) {
        guard !isEditingMode else { return }
        let current = convert(event.locationInWindow, from: nil)
        updateMagnifier(at: current)
        if let adjustmentMode {
            updateAdjustment(adjustmentMode, to: current)
        } else {
            updateSelectionDrag(to: current)
        }
    }

    // 松开是一次鼠标交互的结束点；将当前预览转为确认结果，再清除本次拖动的临时状态。
    override func mouseUp(with event: NSEvent) {
        guard !isEditingMode else { return }
        guard dragStart != nil else { return }

        let releaseLocation = convert(event.locationInWindow, from: nil)

        if let adjustmentMode {
            // 高频鼠标事件可能被合并，松开时必须用最终坐标补算一次。
            updateAdjustment(adjustmentMode, to: releaseLocation)
            self.adjustmentMode = nil
            dragStart = nil

            if isEditorSelectionAdjustment {
                // 编辑器初始调整态由“选择工具”确认选区；单击选区只保持小手状态，
                // 不再引入第二次确认点击。真正发生变化时，mouseUp 才做一次内存裁剪。
                if adjustmentDidMove {
                    onSelectionChangeEnded?(selectedRect)
                }
                window?.invalidateCursorRects(for: self)
            } else if case .move = adjustmentMode, !adjustmentDidMove {
                confirmSelection()
            } else {
                window?.invalidateCursorRects(for: self)
            }
            refreshCaptureCursor()
            return
        }

        // 初次窗口选择或自由拖选：mouseUp 立即确认初始范围并进入带工具栏的调整态。
        let completedAsFreeDrag = updateSelectionDrag(to: releaseLocation)

        dragStart = nil
        let lockedRect = completedAsFreeDrag ? selectedRect : (pressedWindowRect ?? selectedRect)
        let lockedWindowID = completedAsFreeDrag ? nil : pressedWindowID

        // 自由拖选在预览阶段已对齐物理像素，松开时只裁限屏幕范围，不再扩大边界。
        selectedRect = lockedRect.intersection(bounds)
        selectedWindowID = lockedWindowID
        pressedWindowRect = nil
        pressedWindowID = nil
        isFreeDragging = false

        guard selectedRect.width >= minimumSelectionSide,
              selectedRect.height >= minimumSelectionSide else {
            isSelectionLocked = false
            selectedWindowID = nil
            updateHoveredWindow(at: releaseLocation)
            refreshCaptureCursor()
            return
        }

        isSelectionLocked = true
        updateOverlayLayers()
        // mouseUp 已经确定了窗口/自由选区，立即把十字星切回可移动选区的小手。
        // 不能只 invalidateCursorRects：它只是预约 AppKit 稍后重算，用户静止鼠标时
        // 视觉上仍会停留在十字星，直到下一次移动或点击。
        refreshCaptureCursor()
        confirmSelection()
    }

    /// 编辑器刚出现时继续复用选区 View，但关闭窗口悬停，改为 iShot 风格的调整态。
    /// 主工具栏已经可见；用户选择第一个工具以前，内部拖动移动选区，8 个控制点缩放。
    func enterSelectionAdjustmentMode(
        holeRect: CGRect,
        onSelectionChanged: @escaping (CGRect) -> Void,
        onSelectionChangeEnded: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        disableColorCopyShortcut()
        isCaptureCursorActive = true
        isEditingMode = false
        isEditorSelectionAdjustment = true
        showsSelectionBorder = true
        isSelectionLocked = true
        selectedWindowID = nil
        adjustmentMode = nil
        adjustmentStartRect = .zero
        adjustmentDidMove = false
        dragStart = nil
        pressedWindowRect = nil
        pressedWindowID = nil
        hoveredWindowID = nil
        isFreeDragging = false
        selectedRect = holeRect
        windowSnapshot = .empty
        onComplete = nil
        self.onSelectionChanged = onSelectionChanged
        self.onSelectionChangeEnded = onSelectionChangeEnded
        self.onCancel = onCancel
        // 初选 mouseUp 后工具栏立即出现；此时放大镜退出，避免遮挡选区调整控制点。
        hideMagnifier()
        updateOverlayLayers()
        window?.invalidateCursorRects(for: self)
        refreshCaptureCursor()
    }

    /// 选择任一工具后，当前 View 从“选区调整”切换成“固定洞口的被动遮罩”。
    /// 复用 View 和所属 NSPanel 可以保证遮罩像素连续，不经过窗口销毁/重建。
    func enterEditingMode(holeRect: CGRect, onCancel: @escaping () -> Void) {
        disableColorCopyShortcut()
        isCaptureCursorActive = false
        isEditingMode = true
        isEditorSelectionAdjustment = false
        // 调整阶段的边框属于 AppKit；正式编辑后由上层 SwiftUI Canvas 接管边框绘制。
        // 两者在同一轮主线程事件中切换，既保持视觉连续，也避免双层描边叠加。
        showsSelectionBorder = false
        isSelectionLocked = false
        selectedWindowID = nil
        adjustmentMode = nil
        adjustmentStartRect = .zero
        adjustmentDidMove = false
        dragStart = nil
        pressedWindowRect = nil
        pressedWindowID = nil
        hoveredWindowID = nil
        isFreeDragging = false
        selectedRect = holeRect
        windowSnapshot = .empty
        onComplete = nil
        onSelectionChanged = nil
        onSelectionChangeEnded = nil
        self.onCancel = onCancel
        hideMagnifier()
        updateOverlayLayers()
        window?.invalidateCursorRects(for: self)
    }

    /// 始终按当前鼠标位置更新拖选矩形，但把“是否超过阈值”的决定单独返回。
    /// Java 对照：展示状态持续更新，业务决策延迟到 mouseUp，避免 UI 卡在旧的窗口状态。
    @discardableResult
    private func updateSelectionDrag(to current: CGPoint) -> Bool {
        guard let dragStart else { return false }
        let deltaX = current.x - dragStart.x
        let deltaY = current.y - dragStart.y

        selectedRect = pixelAlignedDragRect(CGRect(
            x: dragStart.x,
            y: dragStart.y,
            width: deltaX,
            height: deltaY
        ))
        updateOverlayLayers()

        // 一旦超过阈值就锁定为自由拖选；之后即使鼠标回到起点附近，
        // 本次手势也不能重新变成窗口单击。
        if abs(deltaX) > freeDragThreshold || abs(deltaY) > freeDragThreshold {
            isFreeDragging = true
        }
        return isFreeDragging
    }

    private func beginAdjustment(_ mode: AdjustmentMode, at location: CGPoint) {
        adjustmentMode = mode
        adjustmentStartRect = selectedRect
        adjustmentDidMove = false
        dragStart = location
        refreshCaptureCursor()
    }

    /// 调整阶段始终基于 mouseDown 时的矩形和累计位移计算，而不是反复修改上一帧结果。
    /// Java 对照：这相当于保存 immutable before-state，再由当前输入计算新状态，
    /// 可以避免高频 mouseDragged 产生累计舍入误差和边框抖动。
    private func updateAdjustment(_ mode: AdjustmentMode, to current: CGPoint) {
        guard let dragStart else { return }
        let deltaX = current.x - dragStart.x
        let deltaY = current.y - dragStart.y
        if abs(deltaX) > 1 || abs(deltaY) > 1 {
            adjustmentDidMove = true
            // 一旦人工移动或缩放，选区就不再严格等同于最初命中的系统窗口。
            selectedWindowID = nil
        }

        switch mode {
        case .move:
            let x = min(
                max(adjustmentStartRect.minX + deltaX, bounds.minX),
                bounds.maxX - adjustmentStartRect.width
            )
            let y = min(
                max(adjustmentStartRect.minY + deltaY, bounds.minY),
                bounds.maxY - adjustmentStartRect.height
            )
            selectedRect = CGRect(origin: CGPoint(x: x, y: y), size: adjustmentStartRect.size)

        case let .resize(edges):
            var minX = adjustmentStartRect.minX
            var maxX = adjustmentStartRect.maxX
            var minY = adjustmentStartRect.minY
            var maxY = adjustmentStartRect.maxY

            if edges.contains(.left) {
                minX = min(
                    max(adjustmentStartRect.minX + deltaX, bounds.minX),
                    maxX - minimumSelectionSide
                )
            }
            if edges.contains(.right) {
                maxX = max(
                    min(adjustmentStartRect.maxX + deltaX, bounds.maxX),
                    minX + minimumSelectionSide
                )
            }
            if edges.contains(.bottom) {
                minY = min(
                    max(adjustmentStartRect.minY + deltaY, bounds.minY),
                    maxY - minimumSelectionSide
                )
            }
            if edges.contains(.top) {
                maxY = max(
                    min(adjustmentStartRect.maxY + deltaY, bounds.maxY),
                    minY + minimumSelectionSide
                )
            }
            selectedRect = CGRect(
                x: minX,
                y: minY,
                width: maxX - minX,
                height: maxY - minY
            )
        }

        // 调整预览与初次拖选使用同一像素网格，避免进入工具态时裁剪向外取整，
        // 再把多出边缘像素的图片缩放回原选区，造成内容轻微位移。
        selectedRect = pixelAlignedDragRect(selectedRect)
        updateOverlayLayers()
        if isEditorSelectionAdjustment, adjustmentDidMove {
            // 高频拖动只更新矩形和窗口布局，不在每一帧复制 Retina 位图；
            // mouseUp 再通过 onSelectionChangeEnded 做一次最终内存裁剪。
            onSelectionChanged?(selectedRect)
        }
        window?.invalidateCursorRects(for: self)
        cursorRegion?.refresh()
    }

    private func confirmSelection() {
        guard isSelectionLocked,
              selectedRect.width >= minimumSelectionSide,
              selectedRect.height >= minimumSelectionSide else { return }
        adjustmentMode = nil
        dragStart = nil
        hideMagnifier()
        onComplete?(selectedRect, selectedWindowID)
    }

    /// 供截图会话级键盘监听器调用；非目标屏幕或尚未锁定时不消费 Enter。
    @discardableResult
    func confirmSelectionIfReady() -> Bool {
        guard isInteractionEnabled, isSelectionLocked else { return false }
        confirmSelection()
        return true
    }

    // 键盘事件沿 responder chain 分发；这里处理自己认识的键，其余是否交给 super 由后续分支决定。
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape
            onCancel?()
        } else if event.keyCode == 36 || event.keyCode == 76 { // Return / Numeric Enter
            confirmSelection()
        } else {
            super.keyDown(with: event)
        }
    }

    /// 在 Panel 尚未显示时一次性安装本次会话的数据。
    ///
    /// CGImage 直接交给 CALayer.contents，不转成 NSImage、PNG 或 Data，避免像素复制和编码。
    /// 非目标屏幕传入 nil，只显示整屏遮罩并把点击解释为取消。
    func prepareForCapture(
        frozenImage: CGImage?,
        windowSnapshot: AppKitWindowSnapshot,
        isInteractionEnabled: Bool
    ) {
        self.windowSnapshot = windowSnapshot
        self.isInteractionEnabled = isInteractionEnabled
        isCaptureCursorActive = true
        isEditingMode = false
        isEditorSelectionAdjustment = false
        showsSelectionBorder = isInteractionEnabled
        isSelectionLocked = false
        selectedWindowID = nil
        adjustmentMode = nil
        adjustmentStartRect = .zero
        adjustmentDidMove = false
        dragStart = nil
        pressedWindowRect = nil
        hoveredWindowID = nil
        pressedWindowID = nil
        isFreeDragging = false
        selectedRect = .zero
        self.frozenImage = frozenImage
        currentSampledColor = nil
        frozenImageLayer.contents = frozenImage

        if isInteractionEnabled {
            let location = currentMouseLocation()
            updateHoveredWindow(at: location)
            updateMagnifier(at: location)
        } else {
            hideMagnifier()
            updateOverlayLayers()
        }
        window?.invalidateCursorRects(for: self)
    }

    /// 窗口显示后按当前会话重算，交接或关闭后的延迟回调不能重设旧光标。
    func activateWindowSelectionCursor() {
        refreshCaptureCursor()
    }

    /// 窗口刚显示且鼠标没有移动时，主动设置一次当前光标；后续移动由 cursor rect 维护。
    func refreshCaptureCursor() {
        guard cursorRegion?.isCurrentSession == true else { return }
        window?.invalidateCursorRects(for: self)
        cursorRegion?.refresh(afterTransition: true)
    }

    /// Panel 回收到池中时主动断开对整屏 CGImage 和会话闭包的引用。
    /// orderOut 只会隐藏窗口，不会销毁 contentView；如果不清理，用户图片会一直留在内存。
    func releaseCaptureContent() {
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        cursorTrackingArea = nil
        cursorRegion = nil
        discardCursorRects()
        onComplete = nil
        onCancel = nil
        onSelectionChanged = nil
        onSelectionChangeEnded = nil
        onCopyColor = nil
        windowSnapshot = .empty
        isInteractionEnabled = false
        isCaptureCursorActive = false
        isEditingMode = false
        isEditorSelectionAdjustment = false
        showsSelectionBorder = false
        isSelectionLocked = false
        selectedWindowID = nil
        adjustmentMode = nil
        adjustmentStartRect = .zero
        adjustmentDidMove = false
        dragStart = nil
        pressedWindowRect = nil
        hoveredWindowID = nil
        pressedWindowID = nil
        isFreeDragging = false
        selectedRect = .zero
        frozenImage = nil
        currentSampledColor = nil
        frozenImageLayer.contents = nil
        hideMagnifier()
        updateOverlayLayers()
        window?.invalidateCursorRects(for: self)
    }

}

extension SelectionOverlayView {
    /// 常驻 CALayer 类似可复用的 canvas 图层；冻结图片、遮罩、边框和控制点分别管理。
    private func configureOverlayLayers() {
        wantsLayer = true
        // 裁掉超出图层边界的内容；若阴影画在同一层，也可能被一起裁掉。
        layer?.masksToBounds = true

        frozenImageLayer.contentsGravity = .resize
        // 放大时选择最近像素而不插值，适合放大镜或像素级预览；不改变源图片分辨率。
        frozenImageLayer.magnificationFilter = .nearest
        frozenImageLayer.minificationFilter = .linear
        frozenImageLayer.actions = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull()
        ]

        // 偶奇填充规则让外框与内框重叠区形成洞口；不必为选区上下左右各建一个遮罩窗口。
        dimmingLayer.fillRule = .evenOdd
        dimmingLayer.fillColor = NSColor.black
            .withAlphaComponent(ScreenshotOverlayAppearance.dimmingAlpha)
            .cgColor

        selectionBorderLayer.fillColor = NSColor.clear.cgColor
        selectionBorderLayer.strokeColor = NSColor.systemBlue.cgColor
        selectionBorderLayer.lineWidth = 1.5

        // iShot 风格的 8 个白底蓝边控制点：四个角调整两条边，四个边中点调整单边。
        selectionHandleLayer.fillColor = NSColor.white.cgColor
        selectionHandleLayer.strokeColor = NSColor.systemBlue.cgColor
        selectionHandleLayer.lineWidth = 1

        // 显式关闭隐式动画。截图选区必须严格跟随鼠标，不能让 Core Animation
        // 在旧路径和新路径之间插值，否则快速拖动会产生拖尾。
        dimmingLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        selectionBorderLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        selectionHandleLayer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        // 图层顺序固定：冻结截图在最底层，遮罩居中，选区边框位于最上层。
        // Panel 上屏后完全覆盖实时桌面，因此底层窗口后续重绘不会影响截图交互。
        layer?.addSublayer(frozenImageLayer)
        layer?.addSublayer(dimmingLayer)
        layer?.addSublayer(selectionBorderLayer)
        layer?.addSublayer(selectionHandleLayer)

        // 子 View 位于所有遮罩图层之上。它们都不参与 hit-test，因此不会破坏选框交互。
        resolutionBadge.isHidden = true
        addSubview(resolutionBadge)
        magnifierView.isHidden = true
        addSubview(magnifierView)
        updateOverlayLayers()
    }

    /// 高频拖动只更新图层几何，不重新请求屏幕像素；禁用隐式动画可避免选区追着鼠标缓动。
    private func updateOverlayLayers() {
        // CATransaction 把遮罩洞口和边框作为一次提交处理，避免两层出现不同步的中间帧。
        CATransaction.begin()
        // 关闭本次图层属性修改的隐式动画，让边框/遮罩直接跟随鼠标，而不是缓慢补间到新位置。
        CATransaction.setDisableActions(true)

        frozenImageLayer.frame = bounds
        dimmingLayer.frame = bounds
        selectionBorderLayer.frame = bounds
        selectionHandleLayer.frame = bounds

        let maskPath = CGMutablePath()
        maskPath.addRect(bounds)
        // 只要有选区（悬停窗口、桌面整屏、自由拖选、编辑固定洞口）就挖出透明洞口。
        if !selectedRect.isEmpty {
            maskPath.addRect(selectedRect)
        }
        dimmingLayer.path = maskPath

        selectionBorderLayer.isHidden = !showsSelectionBorder || selectedRect.isEmpty
        // 边框按路径中心向两侧绘制，因此路径向内缩半个线宽，避免边框外扩改变可见选区边缘。
        selectionBorderLayer.path = selectedRect.isEmpty
            ? nil
            : CGPath(
                rect: selectedRect.insetBy(
                    dx: selectionBorderLayer.lineWidth / 2,
                    dy: selectionBorderLayer.lineWidth / 2
                ),
                transform: nil
            )

        selectionHandleLayer.isHidden = !showsSelectionBorder
            || !isSelectionLocked
            || selectedRect.isEmpty
        if isSelectionLocked, !selectedRect.isEmpty {
            let handles = CGMutablePath()
            for (center, _) in resizeHandles(in: selectedRect) {
                handles.addRect(CGRect(
                    x: center.x - handleVisualSize / 2,
                    y: center.y - handleVisualSize / 2,
                    width: handleVisualSize,
                    height: handleVisualSize
                ))
            }
            selectionHandleLayer.path = handles
        } else {
            selectionHandleLayer.path = nil
        }

        CATransaction.commit()
        updateResolutionBadge()
    }

    private func updateResolutionBadge() {
        guard showsSelectionBorder, !selectedRect.isEmpty else {
            resolutionBadge.isHidden = true
            return
        }

        let scaleX = frozenImage.map { CGFloat($0.width) / max(bounds.width, 1) }
            ?? window?.backingScaleFactor
            ?? 1
        let scaleY = frozenImage.map { CGFloat($0.height) / max(bounds.height, 1) }
            ?? window?.backingScaleFactor
            ?? 1
        let pixelWidth = max(Int((selectedRect.width * scaleX).rounded()), 1)
        let pixelHeight = max(Int((selectedRect.height * scaleY).rounded()), 1)
        resolutionBadge.update(text: "\(pixelWidth) × \(pixelHeight)")

        // 标签与选区边缘保持 4pt 间距，内侧回退布局使用相同距离。
        let gap: CGFloat = 4
        let edgePadding: CGFloat = 2
        let badgeSize = resolutionBadge.frame.size
        let x = min(
            max(selectedRect.minX, bounds.minX + edgePadding),
            bounds.maxX - badgeSize.width - edgePadding
        )
        // AppKit 的 Y 轴向上：maxY 是选区上边缘；上方放不下标签时改放选区内部。
        let outsideY = selectedRect.maxY + gap
        let y = outsideY + badgeSize.height <= bounds.maxY - edgePadding
            ? outsideY
            : max(selectedRect.maxY - badgeSize.height - gap, bounds.minY + edgePadding)
        resolutionBadge.setFrameOrigin(CGPoint(x: x, y: y))
        resolutionBadge.isHidden = false
    }
}

extension SelectionOverlayView {
    /// 拖动预览和 mouseUp 最终补算共用同一规则，避免确认时才发生尺寸跳变。
    /// 以冻结图的实际像素比例对齐四条边，而不是向外扩展到整数逻辑点。
    private func pixelAlignedDragRect(_ rect: CGRect) -> CGRect {
        let scaleX = frozenImage.map { CGFloat($0.width) / max(bounds.width, 1) }
            ?? window?.backingScaleFactor
            ?? 1
        let scaleY = frozenImage.map { CGFloat($0.height) / max(bounds.height, 1) }
            ?? window?.backingScaleFactor
            ?? 1
        let standardized = rect.standardized

        func aligned(_ value: CGFloat, lower: CGFloat, upper: CGFloat, scale: CGFloat) -> CGFloat {
            let clipped = min(max(value, lower), upper)
            // 先乘倍率进入像素空间四舍五入，再除倍率回 point；2 倍屏允许 0.5pt 边界，避免多出一列像素。
            let snapped = lower + ((clipped - lower) * scale).rounded() / scale
            return min(max(snapped, lower), upper)
        }

        let minX = aligned(standardized.minX, lower: bounds.minX, upper: bounds.maxX, scale: scaleX)
        let maxX = aligned(standardized.maxX, lower: bounds.minX, upper: bounds.maxX, scale: scaleX)
        let minY = aligned(standardized.minY, lower: bounds.minY, upper: bounds.maxY, scale: scaleY)
        let maxY = aligned(standardized.maxY, lower: bounds.minY, upper: bounds.maxY, scale: scaleY)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// 只让可见的 8 个控制点负责缩放；边框内部的其余区域负责整体移动。
    /// 这样命中语义明确，不会在“用户想移动”时误判为拖动某条边。
    private func resizeEdges(at location: CGPoint) -> ResizeEdges {
        resizeHandles(in: selectedRect)
            .filter { center, _ in
                abs(location.x - center.x) <= resizeHitSlop
                    && abs(location.y - center.y) <= resizeHitSlop
            }
            .min { left, right in
                let leftDistance = hypot(location.x - left.0.x, location.y - left.0.y)
                let rightDistance = hypot(location.x - right.0.x, location.y - right.0.y)
                return leftDistance < rightDistance
            }?.1 ?? []
    }

    // 返回“控制点位置 + 控制边集合”的元组数组；角点带两条边，中点只带一条边。
    private func resizeHandles(in rect: CGRect) -> [(CGPoint, ResizeEdges)] {
        [
            (CGPoint(x: rect.minX, y: rect.minY), [.left, .bottom]),
            (CGPoint(x: rect.midX, y: rect.minY), [.bottom]),
            (CGPoint(x: rect.maxX, y: rect.minY), [.right, .bottom]),
            (CGPoint(x: rect.minX, y: rect.midY), [.left]),
            (CGPoint(x: rect.maxX, y: rect.midY), [.right]),
            (CGPoint(x: rect.minX, y: rect.maxY), [.left, .top]),
            (CGPoint(x: rect.midX, y: rect.maxY), [.top]),
            (CGPoint(x: rect.maxX, y: rect.maxY), [.right, .top])
        ]
    }

    private func resizeCursor(for edges: ResizeEdges) -> NSCursor {
        ScreenshotCursorPolicy.cursor(for: resizeContext(for: edges))
    }

    // 将边集合转换为业务光标语义，最后由统一 Policy 选择 NSCursor，避免散落多套映射。
    private func resizeContext(for edges: ResizeEdges) -> ScreenshotCursorContext {
        switch edges {
        case [.left]: return .resizingSelection(.left)
        case [.right]: return .resizingSelection(.right)
        case [.top]: return .resizingSelection(.top)
        case [.bottom]: return .resizingSelection(.bottom)
        case [.left, .top]: return .resizingSelection(.topLeft)
        case [.right, .top]: return .resizingSelection(.topRight)
        case [.left, .bottom]: return .resizingSelection(.bottomLeft)
        case [.right, .bottom]: return .resizingSelection(.bottomRight)
        default: return .selecting
        }
    }

    private func cursorContext(at location: CGPoint) -> ScreenshotCursorContext {
        // 先判断当前阶段是否拥有光标，再处理拖动模式与悬停；已退出会话的 View 不能继续抢光标。
        guard isCaptureCursorActive else { return .outside }
        if let adjustmentMode {
            switch adjustmentMode {
            case .move: return .movingSelection
            case let .resize(edges): return resizeContext(for: edges)
            }
        }
        guard isSelectionLocked else { return .selecting }
        // 控制点热区跨越选区边界，必须先于内部命中判断。
        let edges = resizeEdges(at: location)
        if !edges.isEmpty { return resizeContext(for: edges) }
        return selectedRect.contains(location) ? .selectionInterior : .selecting
    }

    /// 悬停优先命中最前面的普通应用窗口；鼠标位于桌面时高亮当前整个屏幕。
    private func updateHoveredWindow(at localPoint: CGPoint) {
        guard !isSelectionLocked else { return }
        guard let window else { return }
        let globalPoint = window.convertPoint(toScreen: localPoint)
        let hit = windowSnapshot.frontmostWindow(at: globalPoint)
        hoveredWindowID = hit?.id
        // 命中窗口时高亮窗口区域；桌面没有命中普通窗口时，整个当前屏幕作为候选选区。
        let localRect: CGRect
        if let hit {
            localRect = hit.globalRect
                .offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
                .intersection(bounds)
                .integral
        } else {
            localRect = bounds
        }

        guard selectedRect != localRect else { return }
        selectedRect = localRect
        updateOverlayLayers()
    }

    /// 从当前全局鼠标位置换算到 View，不依赖先收到一次 mouseMoved。
    /// 因此窗口刚显示、鼠标尚未移动时也能计算初始候选。
    private func currentMouseLocation() -> CGPoint {
        guard let window else { return .zero }
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        return convert(pointInWindow, from: nil)
    }
}

extension SelectionOverlayView {
    /// 复制放大镜中心像素的 HEX 颜色。返回值表示当前事件是否已经被消费。
    ///
    /// 只在“窗口悬停/自由拖选”的初选阶段开放；mouseUp 进入工具栏调整态后立即关闭。
    /// 这样 Cmd+C 不会覆盖编辑器原有的复制截图语义。
    @discardableResult
    func copyCurrentColor() -> Bool {
        guard isInteractionEnabled,
              isCaptureCursorActive,
              !isEditingMode,
              !isEditorSelectionAdjustment,
              let color = currentSampledColor else {
            return false
        }

        let hex = color.formatted(as: .hex)
        guard onCopyColor?(hex) == true else { return false }

        magnifierView.showCopied(hex: hex)
        return true
    }

    /// 初始截图选区结束后，颜色复制快捷键的生命周期也随之结束。
    /// 编辑器会复用同一个遮罩 View，因此必须主动断开回调，避免后续 OCR 的 Cmd+C
    /// 仍被残留的取色路径消费。
    func disableColorCopyShortcut() {
        onCopyColor = nil
        currentSampledColor = nil
    }

    /// 根据鼠标位置从冻结图中同步取得一个小像素块和中心颜色。
    ///
    /// Java 对照：frozenImage 类似一次请求内只读的 byte buffer；鼠标移动只做小范围
    /// slice，不会再次调用系统截图服务，也不会为整屏创建 NSBitmapImageRep 副本。
    private func updateMagnifier(at localPoint: CGPoint) {
        guard isInteractionEnabled,
              isCaptureCursorActive,
              !isEditingMode,
              !isEditorSelectionAdjustment,
              !isSelectionLocked,
              let frozenImage else {
            hideMagnifier()
            return
        }
        let pointFromTopLeft = CGPoint(x: localPoint.x - bounds.minX, y: bounds.maxY - localPoint.y)
        guard let sample = ScreenshotPixelSampler.magnifiedSample(
            in: frozenImage, at: pointFromTopLeft, displayedAt: bounds.size
        ) else {
            hideMagnifier()
            return
        }
        currentSampledColor = sample.color
        magnifierView.update(sample: sample, showsCopyShortcut: true)
        magnifierView.frame = ScreenshotPixelMagnifierView.positionedFrame(near: localPoint, within: bounds)
        magnifierView.isHidden = false
    }

    private func hideMagnifier() {
        currentSampledColor = nil
        magnifierView.isHidden = true
        magnifierView.clear()
    }
}
