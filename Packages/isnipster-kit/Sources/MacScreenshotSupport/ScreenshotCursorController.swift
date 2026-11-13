import MacShared
// 阅读路线
// 将选窗、拖选、调整、编辑和取色阶段映射为统一光标；会话 ID 防止旧任务恢复光标时干扰新截图。
// NSCursor.set 改当前光标，cursor rect/tracking 回调还可能再次更新它，因此需要集中管理。
// 官方参考（NSCursor 光标）：https://developer.apple.com/documentation/appkit/nscursor

import AppKit

/// 视图只报告交互含义；原生光标的映射集中在此处，不由窗口各自决定。
public enum ScreenshotCursorContext {
    case selecting
    case selectionInterior
    case movingSelection
    case resizingSelection(NSCursor.FrameResizePosition)
    case drawing
    case textInput
    case textAnnotation
    case movingText
    case ocrText
    case toolbar
    case outside
}

@MainActor
public enum ScreenshotCursorPolicy {
    public static func cursor(for context: ScreenshotCursorContext) -> NSCursor {
        switch context {
        case .selecting: return .crosshair
        case .selectionInterior: return .openHand
        case .movingSelection: return .closedHand
        case let .resizingSelection(position): return .frameResize(position: position, directions: .all)
        case .textInput, .ocrText: return .iBeam
        case .textAnnotation: return .openHand
        case .movingText: return .closedHand
        case .toolbar, .outside: return .arrow
        case .drawing: return .crosshair
        }
    }
}

/// 一次截图只有一个光标所有者。所有区域共用当前会话标识，结束后旧视图的延迟事件失效。
/// 这里只监听本应用的鼠标事件，不吞掉事件，也不改变窗口焦点或截图业务状态。
@MainActor
public final class ScreenshotCursorController {
    private var sessionID: UUID?
    private var regions: [WeakRegion] = []
    private var mouseMonitor: Any?
    private var pendingRefreshID: UUID?
    private var transitionRefresh: Task<Void, Never>?
    private weak var dragRegion: ScreenshotCursorRegion?

    public init() {}

    /// 新截图必须丢弃旧窗口注册和待执行刷新；选区到编辑器的交接仍复用同一会话。
    @discardableResult
    public func beginSelection() -> ScreenshotCursorSession {
        if let sessionID { end(matching: sessionID) }
        let id = UUID()
        sessionID = id
        regions.removeAll()
        ScreenshotCursorPolicy.cursor(for: .selecting).set()
        // local monitor 在本应用派发事件前执行；返回 nil 消费事件，返回 event 才继续交给 responder chain。
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved, .mouseEntered, .mouseExited,
                .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                .cursorUpdate, .flagsChanged, .keyUp
            ]
        ) { [weak self] event in
            guard let self, self.sessionID == id else { return event }
            if event.type == .leftMouseDown {
                self.dragRegion = self.region(at: NSEvent.mouseLocation)
            } else if event.type == .leftMouseUp {
                self.dragRegion = nil
            }
            // 先让原处理器更新选区/工具状态，再在本轮事件分发完成后重新计算。
            self.scheduleRefresh()
            return event
        }
        return ScreenshotCursorSession(controller: self, id: id)
    }

    fileprivate func end(matching id: UUID) {
        guard sessionID == id else { return }
        sessionID = nil
        pendingRefreshID = nil
        transitionRefresh?.cancel()
        transitionRefresh = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        dragRegion = nil
        regions.forEach { $0.value?.invalidate() }
        regions.removeAll()
        ScreenshotCursorPolicy.cursor(for: .outside).set()
    }

    fileprivate func register(_ region: ScreenshotCursorRegion, matching id: UUID) -> UUID? {
        guard sessionID == id else { return nil }
        regions.removeAll { $0.value == nil || $0.value === region }
        regions.append(WeakRegion(value: region))
        return id
    }

    fileprivate func isCurrent(_ id: UUID?) -> Bool {
        id != nil && id == sessionID
    }

    /// 使用鼠标所在的最上层可交互窗口，而非 keyWindow：点击属性栏后，
    /// 焦点可能已交还画布，但鼠标仍在属性栏，此时仍应显示箭头。
    private func refresh() {
        guard sessionID != nil else { return }
        let point = NSEvent.mouseLocation
        // 拖动跨过工具栏或画布边界时仍属于起始区域，松开后恢复位置命中。
        let region = dragRegion.flatMap { $0.isActive ? $0 : nil } ?? self.region(at: point)
        guard let region, let view = region.view, let window = view.window else { return }
        // 坐标转换中的 nil 表示所属窗口坐标系，不表示屏幕坐标；跨到屏幕还需窗口转换 API。
        let localPoint = view.convert(window.convertPoint(fromScreen: point), from: nil)
        ScreenshotCursorPolicy.cursor(for: region.context(localPoint)).set()
    }

    private func region(at point: CGPoint) -> ScreenshotCursorRegion? {
        guard let sessionID,
              let windowNumbers = NSWindow.windowNumbers(options: []) else { return nil }
        // orderedWindows 是脚本窗口列表，通常不包含 NSPanel。
        // WindowServer 的窗口编号按实际前后顺序排列，包含截图的非激活面板。
        // 窗口按前后顺序命中，区域在同窗口内反向遍历优先取最后注册项；与 key window 无关。
        for number in windowNumbers {
            guard let window = NSApp.window(withWindowNumber: number.intValue),
                  window.isVisible, !window.ignoresMouseEvents,
                  window.frame.contains(point) else { continue }
            for entry in regions.reversed() {
                guard let region = entry.value, region.sessionID == sessionID,
                      let view = region.view, view.window === window,
                      !view.isHiddenOrHasHiddenAncestor else { continue }
                let localPoint = view.convert(window.convertPoint(fromScreen: point), from: nil)
                guard view.bounds.contains(localPoint) else { continue }
                return region
            }
            // 鼠标位于系统颜色面板等独立窗口时，由该窗口自行管理光标。
            return nil
        }
        return nil
    }

    private func scheduleRefresh() {
        guard let sessionID, pendingRefreshID == nil else { return }
        // 合并同一轮重复刷新请求；pendingRefreshID 非空时不继续排队，避免 mousemove 堆积主队列任务。
        let requestID = UUID()
        pendingRefreshID = requestID
        // 把闭包排到主队列稍后执行；常用于等待当前布局/焦点切换结束，不会创建后台工作线程。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.sessionID == sessionID,
                  self.pendingRefreshID == requestID else { return }
            self.pendingRefreshID = nil
            self.refresh()
        }
    }

    /// 窗口交接会异步重算 cursor rect。同步刷新后再约 16ms 补刷新，
    /// 单击选窗口且鼠标保持静止时，也能进入手形状态。回调读取最新状态，不保存旧光标。
    private func refreshAfterTransition() {
        refresh()
        scheduleRefresh()
        transitionRefresh?.cancel()
        guard let sessionID else { return }
        transitionRefresh = Task { @MainActor [weak self] in
            // sleep 让当前 Task 挂起，其他任务仍可运行；try 说明等待期间取消可能抛出 CancellationError。
            // 16ms 是延后补偿，不是与显示器垂直同步；高刷屏、系统调度或负载会改变实际唤醒时刻。
            do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            guard let self, self.sessionID == sessionID else { return }
            self.refresh()
        }
    }

    fileprivate func refresh(matching id: UUID, afterTransition: Bool) {
        guard sessionID == id else { return }
        if afterTransition {
            refreshAfterTransition()
        } else {
            refresh()
        }
    }

    // Swift Array 不能直接声明元素是 weak，所以用小结构体包装弱引用；管理器不会因此延长 View 的生命。
    private struct WeakRegion {
        weak var value: ScreenshotCursorRegion?
    }
}

/// 随截图从选择阶段交给编辑器；旧视图只能操作自己的会话，不能重新加入下一次截图。
@MainActor
public final class ScreenshotCursorSession {
    fileprivate let controller: ScreenshotCursorController
    fileprivate let id: UUID

    fileprivate init(controller: ScreenshotCursorController, id: UUID) {
        self.controller = controller
        self.id = id
    }

    public var isCurrent: Bool { controller.isCurrent(id) }

    public func register(
        view: NSView,
        context: @escaping (CGPoint) -> ScreenshotCursorContext
    ) -> ScreenshotCursorRegion? {
        guard isCurrent else { return nil }
        return ScreenshotCursorRegion(view: view, session: self, context: context)
    }

    public func refresh(afterTransition: Bool = false) {
        controller.refresh(matching: id, afterTransition: afterTransition)
    }

    public func end() {
        controller.end(matching: id)
    }
}

/// 由 NSView 持有的轻量注册对象；管理器只弱引用它，窗口销毁后不会残留光标所有权。
@MainActor
public final class ScreenshotCursorRegion {
    private let session: ScreenshotCursorSession
    fileprivate weak var view: NSView?
    fileprivate var sessionID: UUID?
    fileprivate let context: (CGPoint) -> ScreenshotCursorContext

    fileprivate init(view: NSView, session: ScreenshotCursorSession,
                     context: @escaping (CGPoint) -> ScreenshotCursorContext) {
        self.session = session
        self.view = view
        self.context = context
        sessionID = session.controller.register(self, matching: session.id)
    }

    public var isCurrentSession: Bool {
        sessionID != nil && session.isCurrent
    }

    public var isActive: Bool {
        isCurrentSession && view?.window?.isVisible == true
            && view?.isHiddenOrHasHiddenAncestor == false
    }

    fileprivate func invalidate() {
        sessionID = nil
        view?.discardCursorRects()
    }

    public func refresh(afterTransition: Bool = false) {
        guard isActive else { return }
        session.refresh(afterTransition: afterTransition)
    }
}
