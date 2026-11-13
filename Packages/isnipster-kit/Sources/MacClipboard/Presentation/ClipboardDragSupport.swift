import MacShared
import MacPreferences
// 阅读路线
// NSViewRepresentable 把光标区域和原生拖拽源嵌进 SwiftUI 卡片；移动达到阈值才开始拖出。
// 区分单击粘贴与拖出文件：拖拽会话由 AppKit 接管，结束回调再恢复临时交互状态。
// 官方参考（原生拖拽源）：https://developer.apple.com/documentation/appkit/nsdraggingsource

import AppKit
import ClipboardFeature
import SwiftUI

/// 为 SwiftUI 内容块提供稳定的 AppKit 光标区域。`NSCursor.set()` 只会临时
/// 改变当前光标，AppKit 下一次重新计算时可能覆盖；cursor rect 会持续生效。
@MainActor
struct ClipboardPointingHandCursorRegion: NSViewRepresentable {
    // SwiftUI 建立原生视图时调用 makeNSView；创建后通过 updateNSView 同步新状态，不应每次刷新都重建。
    func makeNSView(context: Context) -> ClipboardPointingHandCursorView {
        ClipboardPointingHandCursorView(frame: .zero)
    }

    // 该桥接没有随状态变化的输入参数，所以 update 留空；光标区域在 AppKit 的布局回调中刷新。
    func updateNSView(_ nsView: ClipboardPointingHandCursorView, context: Context) {}
}

/// 只提供 pointing-hand 光标区域且不拦截鼠标事件的透明 AppKit 视图。
@MainActor
final class ClipboardPointingHandCursorView: NSView {
    /// 只负责光标，不参与命中测试，避免遮挡卡片的点击和右键菜单。
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    // AppKit 重建鼠标区域时调用；注册 cursor rect 比只执行一次 NSCursor.set 更适合持续显示指定光标。
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // 要求 AppKit 重新询问指定 View 的 cursor rect；用于工具切换后鼠标未移动的情况。
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }
}

/// 统一处理卡片单击，以及图片和文件的标题栏拖拽，避免手势相互触发。
@MainActor
struct ClipboardCardInteraction: NSViewRepresentable {
    let entry: ClipboardEntry
    let headerDragHeight: CGFloat
    let onClick: () -> Void
    let onDragCompleted: () -> Void

    func makeNSView(context: Context) -> ClipboardCardInteractionView {
        ClipboardCardInteractionView(
            entry: entry,
            headerDragHeight: headerDragHeight,
            onClick: onClick,
            onDragCompleted: onDragCompleted
        )
    }

    func updateNSView(_ nsView: ClipboardCardInteractionView, context: Context) {
        nsView.entry = entry
        nsView.headerDragHeight = headerDragHeight
        nsView.onClick = onClick
        nsView.onDragCompleted = onDragCompleted
    }

    static func dismantleNSView(_ nsView: ClipboardCardInteractionView, coordinator: ()) {
        nsView.resetInteraction()
    }
}

/// 以真实文件 URL 发起拖拽，并接收会话结束回调；图片先保存到临时文件，不使用 NSFilePromiseProvider。
@MainActor
final class ClipboardCardInteractionView: NSView, NSDraggingSource {
    var entry: ClipboardEntry
    var headerDragHeight: CGFloat
    var onClick: () -> Void
    var onDragCompleted: () -> Void

    private var mouseDownEvent: NSEvent?
    private var isDragging = false
    private var didMove = false

    init(
        entry: ClipboardEntry,
        headerDragHeight: CGFloat,
        onClick: @escaping () -> Void,
        onDragCompleted: @escaping () -> Void
    ) {
        self.entry = entry
        self.headerDragHeight = headerDragHeight
        self.onClick = onClick
        self.onDragCompleted = onDragCompleted
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    // NSCoder 初始化用于 Storyboard/XIB 解档；本类型仅支持代码创建，下面明确拒绝解档构造路径。
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    // 控制非 key 窗口的第一击是否直接触发控件；返回 true 可避免必须先激活再点第二次。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { resetInteraction() }
        window?.invalidateCursorRects(for: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        window?.invalidateCursorRects(for: self)
    }

    // AppKit 鼠标按下回调；event.locationInWindow 属于窗口坐标，传给局部几何计算前需要转换。
    override func mouseDown(with event: NSEvent) {
        resetInteraction()
        mouseDownEvent = event
    }

    // 拖过 4pt 阈值后只发起一次原生拖拽，后续由 NSDraggingSession 接管，而不是每帧重新导出文件。
    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let mouseDownEvent else { return }
        let start = convert(mouseDownEvent.locationInWindow, from: nil)
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(current.x - start.x, current.y - start.y) >= 4 else { return }
        didMove = true
        // 只有从图片/文件标题栏开始的移动才导出文件，正文拖动不会误粘贴。
        guard headerDragHeight > 0, start.y >= bounds.maxY - headerDragHeight else { return }

        let writers = dragWriters()
        guard !writers.isEmpty else { return }

        let items = writers.enumerated().map { index, writer in
            // NSDraggingItem 同时携带数据提供者与拖拽预览；setDraggingFrame 的尺寸只改鼠标跟随图，不会缩小原文件。
            let item = NSDraggingItem(pasteboardWriter: writer)
            let offset = CGFloat(min(index, 3)) * 3
            item.setDraggingFrame(
                NSRect(
                    x: start.x - 20 + offset,
                    y: start.y - 20 - offset,
                    width: 40,
                    height: 40
                ),
                contents: dragImage(for: writer)
            )
            return item
        }

        isDragging = true
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        if items.count > 1 {
            session.draggingFormation = .stack
        }
    }

    // 只有未进入拖拽的按下/松开组合才触发普通单击；真正拖拽的完成由 draggingSession 回调处理。
    override func mouseUp(with event: NSEvent) {
        let shouldClick = mouseDownEvent != nil && !isDragging && !didMove
            && bounds.contains(convert(event.locationInWindow, from: nil))
        resetInteraction()
        if shouldClick {
            onClick()
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        // 结束结果为空表示取消或未完成操作；仅非空时回调，通知外层将原记录标记为使用过。
        operation: NSDragOperation
    ) {
        if !operation.isEmpty {
            onDragCompleted()
        }
        resetInteraction()
    }

    func resetInteraction() {
        mouseDownEvent = nil
        isDragging = false
        didMove = false
    }

    // 文件直接提供 NSURL；PNG 先落临时文件再提供 URL。文本、网页和颜色不从标题栏走文件拖拽。
    private func dragWriters() -> [NSPasteboardWriting] {
        switch entry.content {
        case let .files(urls):
            return urls.map { $0 as NSURL }
        case let .imagePNG(data, _, _):
            guard let url = Self.makeTemporaryImageURL(data: data, entryID: entry.id) else {
                return []
            }
            return [url as NSURL]
        case .text, .url, .color:
            return []
        }
    }

    private func dragImage(for writer: NSPasteboardWriting) -> NSImage {
        if let url = writer as? NSURL, let path = url.path {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(systemSymbolName: "doc", accessibilityDescription: nil) ?? NSImage()
    }

    private static func makeTemporaryImageURL(data: Data, entryID: UUID) -> URL? {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("isnipster-drag", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            cleanupExpiredFiles(in: directory)

            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let suffix = entryID.uuidString.prefix(6)
            let fileName = "iSnipster-\(formatter.string(from: .now))-\(suffix).png"
            let url = directory.appendingPathComponent(fileName)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private static func cleanupExpiredFiles(in directory: URL) {
        let expirationDate = Date().addingTimeInterval(-24 * 60 * 60)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files {
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate < expirationDate else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
