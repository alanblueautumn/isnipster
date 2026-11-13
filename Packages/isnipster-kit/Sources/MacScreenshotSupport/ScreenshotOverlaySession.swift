import AppKit
import CaptureFeature

/// 编辑器只申请一次截图的遮罩会话，不接触选择窗口的具体类型或集合。
@MainActor
public protocol ScreenshotOverlayProviding: AnyObject {
    func makeEditorSession(
        selection: ScreenSelection,
        frozenFrame: FrozenScreenFrame
    ) -> any ScreenshotOverlaySession
}

/// 会话独占遮罩窗口和光标标识；关闭必须幂等，且只能释放本次截图的资源。
@MainActor
public protocol ScreenshotOverlaySession: AnyObject {
    var cursorSession: ScreenshotCursorSession { get }

    func show(
        onSelectionChanged: @escaping (CGRect) -> Void,
        onSelectionChangeEnded: @escaping (CGRect) -> Void,
        onCancel: @escaping () -> Void
    )
    func confirmSelection(_ selection: ScreenSelection, onCancel: @escaping () -> Void)
    func focusSelectionAdjustment()
    func owns(window: NSWindow) -> Bool
    func close()
}
