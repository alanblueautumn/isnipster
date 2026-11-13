import MacShared
import MacPreferences
// 阅读路线
// 将普通滚轮的纵向增量适配到横向历史条，保留触控板横向行为。
// Coordinator 保存监听器与原生滚动视图；dismantleNSView 对应拆桥时的资源清理。
// 官方参考（SwiftUI 与 NSView 桥接）：https://developer.apple.com/documentation/swiftui/nsviewrepresentable

import AppKit
import SwiftUI

/// 将普通鼠标的纵向滚轮转换为时间线的横向位移，同时彻底关闭原生横向滚动条。
/// 触控板原本产生的横向增量仍按原方向使用。
@MainActor
struct HorizontalMouseWheelSupport: NSViewRepresentable {
    // Coordinator 是桥接期间持续存在的引用对象，用于保存代理和监听；不能把这些状态只放在短生命周期 View 值里。
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // SwiftUI 建立原生视图时调用 makeNSView；创建后通过 updateNSView 同步新状态，不应每次刷新都重建。
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.install(for: view)
        // 把闭包排到主队列稍后执行；常用于等待当前布局/焦点切换结束，不会创建后台工作线程。
        DispatchQueue.main.async {
            context.coordinator.configureScrollView()
        }
        return view
    }

    // 把本轮 SwiftUI 输入同步到已有 NSView；涉及文本/选择时先判断差异，避免无意义赋值打断原生交互。
    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.hostView = nsView
        DispatchQueue.main.async {
            context.coordinator.configureScrollView()
        }
    }

    // 桥接视图移出层级时清理回调与监听；类似 Vue onUnmounted，ARC 本身不会帮忙注销事件。
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    /// 安装滚轮事件监听并维护当前 SwiftUI 内容所在的原生滚动视图。
    @MainActor
    final class Coordinator {
        weak var hostView: NSView?
        private weak var scrollView: NSScrollView?
        private var eventMonitor: Any?

        func install(for view: NSView) {
            hostView = view
            guard eventMonitor == nil else { return }
            // local monitor 在本应用派发事件前执行；返回 nil 消费事件，返回 event 才继续交给 responder chain。
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self else { return event }
                return self.handleScrollWheel(event)
            }
        }

        func configureScrollView() {
            guard let hostView, let enclosingScrollView = hostView.enclosingScrollView else {
                return
            }
            scrollView = enclosingScrollView
            enclosingScrollView.hasHorizontalScroller = false
            enclosingScrollView.horizontalScroller?.isHidden = true
            enclosingScrollView.autohidesScrollers = true
        }

        /// 停止滚轮监听并断开原生视图引用；桥接卸载后旧事件不应继续移动新页面。
        func stop() {
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
            scrollView = nil
        }

        /// 只处理目标滚动区域的滚轮；按输入设备增量映射横向位置，其他事件继续分发。
        private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
            guard let hostView,
                  event.window === hostView.window else {
                return event
            }
            if scrollView == nil {
                configureScrollView()
            }
            guard let scrollView,
                  let documentView = scrollView.documentView else {
                return event
            }

            // 坐标转换中的 nil 表示所属窗口坐标系，不表示屏幕坐标；跨到屏幕还需窗口转换 API。
            let localPoint = hostView.convert(event.locationInWindow, from: nil)
            guard hostView.bounds.contains(localPoint) else { return event }

            let horizontalDelta = event.scrollingDeltaX
            let verticalDelta = event.scrollingDeltaY
            // 取绝对值较大的方向，纵向滚轮因此能驱动横向历史条；触控板已有横向增量也沿用同一入口。
            let rawDelta = abs(horizontalDelta) > abs(verticalDelta)
                ? horizontalDelta
                : verticalDelta
            guard rawDelta != 0 else { return event }

            // 精细设备使用原始点增量，传统鼠标滚轮额外放大步长；这决定手感，不是改变列表缩放倍率。
            let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 24
            let clipView = scrollView.contentView
            let minimumX = documentView.bounds.minX
            let maximumX = max(
                minimumX,
                documentView.bounds.maxX - clipView.bounds.width
            )
            let nextX = min(
                maximumX,
                max(minimumX, clipView.bounds.origin.x - rawDelta * multiplier)
            )
            guard abs(nextX - clipView.bounds.origin.x) > 0.01 else { return event }

            clipView.scroll(to: NSPoint(x: nextX, y: clipView.bounds.origin.y))
            // 移动 clipView 后通知 NSScrollView 同步其滚动状态；只修改原点而不反映状态可能让滚动指示不同步。
            scrollView.reflectScrolledClipView(clipView)
            return nil
        }
    }
}
