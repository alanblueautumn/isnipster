import AppKit
import CaptureFeature
import MacScreenshotSupport

/// 选择器先暂存仍可见的窗口，编辑器随后领取会话，交接期间复用同一批窗口。
@MainActor
public final class ScreenshotOverlayCoordinator: ScreenshotOverlayProviding {
    private struct StagedSelection {
        let panels: [SelectionPanel]
        let cursorSession: ScreenshotCursorSession
    }

    private let cursorController: ScreenshotCursorController
    private var stagedSelection: StagedSelection?

    public init(cursorController: ScreenshotCursorController) {
        self.cursorController = cursorController
    }

    var hasStagedPanels: Bool { stagedSelection != nil }

    func checkoutSelectionPanel(for screen: NSScreen, cursorSession: ScreenshotCursorSession) -> SelectionPanel {
        SelectionPanel(screen: screen, cursorSession: cursorSession)
    }

    func stageSelectionPanels(_ panels: [SelectionPanel], cursorSession: ScreenshotCursorSession) {
        discardStagedPanels()
        stagedSelection = StagedSelection(panels: panels, cursorSession: cursorSession)
    }

    public func makeEditorSession(
        selection: ScreenSelection,
        frozenFrame: FrozenScreenFrame
    ) -> any ScreenshotOverlaySession {
        if let stagedSelection, stagedSelection.cursorSession.isCurrent {
            // 窗口与光标一起交接；选择器后续清理时不再拥有这些资源。
            self.stagedSelection = nil
            return SelectionOverlaySession(
                panels: stagedSelection.panels,
                cursorSession: stagedSelection.cursorSession,
                selection: selection
            )
        }

        discardStagedPanels()
        let cursorSession = cursorController.beginSelection()
        let panels = NSScreen.screens.map { screen in
            let panel = checkoutSelectionPanel(for: screen, cursorSession: cursorSession)
            let isCaptureScreen = panel.displayID == selection.displayID
            panel.selectionView.prepareForCapture(
                frozenImage: isCaptureScreen ? frozenFrame.image.cgImage : nil,
                windowSnapshot: .empty,
                isInteractionEnabled: isCaptureScreen
            )
            return panel
        }
        return SelectionOverlaySession(panels: panels, cursorSession: cursorSession, selection: selection)
    }

    func discardStagedPanels() {
        guard let stagedSelection else { return }
        self.stagedSelection = nil
        stagedSelection.cursorSession.end()
        closeSelectionPanels(stagedSelection.panels)
    }

    func recycleSelectionPanels(_ panels: [SelectionPanel]) {
        closeSelectionPanels(panels)
    }
}

/// 具体选区窗口只在 MacCapture 内部流转，编辑器通过协议使用交互与生命周期操作。
@MainActor
private final class SelectionOverlaySession: ScreenshotOverlaySession {
    let cursorSession: ScreenshotCursorSession
    private var panels: [SelectionPanel]
    private var selection: ScreenSelection
    private var isShown = false
    private var isClosed = false

    init(panels: [SelectionPanel], cursorSession: ScreenshotCursorSession, selection: ScreenSelection) {
        self.panels = panels
        self.cursorSession = cursorSession
        self.selection = selection
    }

    func show(
        onSelectionChanged: @escaping (CGRect) -> Void,
        onSelectionChangeEnded: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !isClosed, !isShown, cursorSession.isCurrent else { return }
        isShown = true
        for panel in panels {
            // 选择器交接前暂时忽略鼠标；必须先恢复接收，再刷新光标。
            panel.ignoresMouseEvents = false
            let overlayView = panel.selectionView
            let localHole = holeRect(in: panel)
            if panel.displayID == selection.displayID {
                overlayView.enterSelectionAdjustmentMode(
                    holeRect: localHole,
                    onSelectionChanged: { [weak panel] localRect in
                        guard let panel else { return }
                        onSelectionChanged(localRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY))
                    },
                    onSelectionChangeEnded: { [weak panel] localRect in
                        guard let panel else { return }
                        onSelectionChangeEnded(localRect.offsetBy(dx: panel.frame.minX, dy: panel.frame.minY))
                    },
                    onCancel: onCancel
                )
            } else {
                overlayView.enterEditingMode(holeRect: localHole, onCancel: onCancel)
            }
            // 兜底创建的窗口在准备好首帧后显示；接管的窗口保持原有显示次序。
            if !panel.isVisible {
                panel.displayIfNeeded()
                panel.orderFrontRegardless()
            }
        }
    }

    func confirmSelection(_ selection: ScreenSelection, onCancel: @escaping () -> Void) {
        guard !isClosed, cursorSession.isCurrent else { return }
        self.selection = selection
        for panel in panels {
            panel.selectionView.enterEditingMode(holeRect: holeRect(in: panel), onCancel: onCancel)
            panel.ignoresMouseEvents = false
        }
    }

    func focusSelectionAdjustment() {
        guard !isClosed, cursorSession.isCurrent,
              let panel = panels.first(where: { $0.displayID == selection.displayID }) else { return }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(panel.selectionView)
        panel.selectionView.refreshCaptureCursor()
    }

    func owns(window: NSWindow) -> Bool {
        !isClosed && panels.contains { $0 === window }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // 先让旧回调失效，再拆除窗口；end 只会结束匹配的光标会话。
        cursorSession.end()
        let ownedPanels = panels
        panels.removeAll(keepingCapacity: false)
        closeSelectionPanels(ownedPanels)
    }

    private func holeRect(in panel: SelectionPanel) -> CGRect {
        guard panel.frame.intersects(selection.globalRect) else { return .zero }
        return selection.globalRect
            .offsetBy(dx: -panel.frame.minX, dy: -panel.frame.minY)
            .intersection(panel.selectionView.bounds)
    }
}

@MainActor
private func closeSelectionPanels(_ panels: [SelectionPanel]) {
    panels.forEach { panel in
        panel.orderOut(nil)
        panel.ignoresMouseEvents = true
        panel.selectionView.releaseCaptureContent()
        panel.contentView = nil
        panel.close()
    }
}
