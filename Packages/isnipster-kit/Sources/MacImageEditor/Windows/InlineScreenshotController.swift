import MacShared
import MacScreenshotSupport
import MacTranslation
import RecognitionFeature
// 阅读路线
// 一次截图会话的协调器：初始选区可调整，选工具后固定；异步命令完成后更新 session/document。
// UIKit 的 ViewController、Web 的页面控制层可作类比，但这里需要管理多个 AppKit 窗口。
// 官方参考（NSWindow 窗口坐标与焦点）：https://developer.apple.com/documentation/appkit/nswindow

import AppKit
import CaptureFeature
import ClipboardFeature
import ColorPickerFeature
import CoreImage
import ImageEditorFeature
import ImageTranslationFeature
import Observation
import iSnipsterCore
import SwiftUI
@preconcurrency import Translation

/// 编排截图选区、编辑画布和完成类动作；工具栏窗口交给专用控制器管理。
/// 画布和工具栏共享同一个 session，因此切换工具不需要重新生成位图。
@MainActor
final class InlineScreenshotController {
    let documentID: UUID
    var onClose: ((UUID) -> Void)?

    private let session: InlineEditorSession
    private let operations: EditorOperationCoordinator
    private let toolShortcuts = ScreenshotToolShortcutStore.load()
    /// 初始 mouseUp 后选区仍可变；点击任一工具后 isAdjustingSelection 变为 false，
    /// 从这一刻起 selection 才成为本次编辑会话的固定截图范围。
    private var selection: ScreenSelection
    private let frozenFrame: FrozenScreenFrame
    private let onExport: (EditorExportResult, CGRect) -> Void
    private let onCopyColor: (SampledColor, ColorFormat) -> Bool
    private let onCopyText: (String) throws -> Void
    private let onCancel: () -> Void
    private let translationClient: AppleTranslationClient
    private let overlaySession: any ScreenshotOverlaySession
    private var canvasPanel: NSPanel?
    private var canvasContentView: EditorFirstMouseHostingView<InlineEditorCanvas>?
    private var toolbarController: ScreenshotToolbarPanelController?
    private var colorPickerMagnifierController: ScreenshotColorPickerMagnifierController?
    /// NSEvent 本地监听器返回的是一个不透明 token，必须强引用并在会话结束时移除。
    /// 它只拦截发往当前应用的按键，不是全局键盘监听，不需要输入监控权限。
    private var keyboardMonitor: Any?
    private var isDismissed = false

    init(
        document: ImageDocument,
        selection: ScreenSelection,
        frozenFrame: FrozenScreenFrame,
        exportService: EditorExportService,
        onExport: @escaping (EditorExportResult, CGRect) -> Void,
        onOCR: @escaping @MainActor () async throws -> [OCRTextRegion],
        onTranslate: @escaping @MainActor (String?, String) async throws -> ImageTranslationResult,
        onSmartRedaction: @escaping @MainActor () async throws -> Int,
        onCopyColor: @escaping (SampledColor, ColorFormat) -> Bool,
        onCopyText: @escaping (String) throws -> Void,
        onCancel: @escaping () -> Void,
        translationLanguages: TranslationLanguagePair,
        translationClient: AppleTranslationClient,
        translationTimeout: @escaping @MainActor () -> Int,
        overlaySession: any ScreenshotOverlaySession
    ) {
        documentID = document.id
        let session = InlineEditorSession(document: document, cursorSession: overlaySession.cursorSession)
        self.session = session
        operations = EditorOperationCoordinator(session: session, translationSession: translationClient,
            translationTimeout: translationTimeout, exportService: exportService, recognize: onOCR, translate: onTranslate, redact: onSmartRedaction)
        // 新截图使用设置中的完整语言方向，避免被文本翻译窗口的目标语言覆盖。
        session.translationSourceLanguage = translationLanguages.sourceLanguage
        session.translationTargetLanguage = translationLanguages.targetLanguage
        self.selection = selection
        self.frozenFrame = frozenFrame
        self.onExport = onExport
        self.onCopyColor = onCopyColor
        self.onCopyText = onCopyText
        self.onCancel = onCancel
        self.translationClient = translationClient
        self.overlaySession = overlaySession
        operations.onOCRChange = { [weak self] in self?.canvasContentView?.refreshCursor() }
    }

    /// 展示顺序是背景 → 画布 → 工具栏，再安装输入监听；相当于先建立容器再挂载子组件。
    /// AppKit 窗口不是 DOM，必须手动维护前后层级和 First Responder（键盘焦点）。
    func show() {
        // 截图编辑器必须延续选择阶段的“不激活应用”语义。
        // 如果这里调用 NSApp.activate，鼠标下方原应用会在截图确认瞬间失去 active/key
        // 状态并重绘标题栏、材质和控件；画布首帧尚未覆盖完成时，用户看到的就是
        // 目标窗口局部闪烁。下面所有编辑窗口都使用 nonactivatingPanel，仍然可以成为
        // key window 接收 Esc 和文本输入，但不会改变原应用的激活外观。
        showBackdropPanels()
        showCanvasPanel()
        showToolbarPanel()
        if let canvasPanel {
            let magnifier = ScreenshotColorPickerMagnifierController(
                canvasWindow: canvasPanel,
                canvasView: canvasContentView
            ) { [weak self] in
                guard let self, !self.isDismissed,
                      !self.session.isAdjustingSelection, !self.session.isOCRMode,
                      !self.session.isProcessing, self.session.document.selectedTool == .colorPicker else { return nil }
                return self.session.document.original.cgImage
            }
            colorPickerMagnifierController = magnifier
            magnifier.start()
        }
        installKeyboardMonitor()
        focusSelectionAdjustment()
    }

    /// 第一次选择工具或执行命令时，选区从可调整态单向进入固定编辑态。
    /// 返回 false 表示最终裁剪失败，调用方不应继续执行 OCR、复制等后续命令。
    @discardableResult
    private func confirmSelectionForEditing(revealsStylePanel: Bool) -> Bool {
        guard !isDismissed else { return false }

        if session.isAdjustingSelection {
            do {
                // 即使最后一次 mouseUp 回调已经裁剪过，这里仍以当前 selection 做最终确认。
                // CGImage.cropping 只创建裁剪图引用，不会经过 ScreenCaptureKit 或磁盘。
                let cropped = try frozenFrame.cropped(to: selection)
                session.document.replaceOriginal(with: cropped, recordingUndo: false)
            } catch {
                onCancel()
                return false
            }

            session.isAdjustingSelection = false
            overlaySession.confirmSelection(selection, onCancel: onCancel)
            canvasContentView?.isHidden = false
            // 控制整个窗口是否接收鼠标；设为 true 时事件可落到下层窗口，不能把它当作阻止点击穿透。
            canvasPanel?.ignoresMouseEvents = false
        }

        if revealsStylePanel {
            toolbarController?.showStylePanel()
        }
        focusCanvas()
        return true
    }

    /// mouseUp 后只裁剪一次当前冻结帧，让后续点工具时画布已经拥有正确尺寸的基底图。
    func finishSelectionAdjustment(globalRect: CGRect) {
        updateSelectionLayout(globalRect: globalRect)
        do {
            session.document.replaceOriginal(with: try frozenFrame.cropped(to: selection), recordingUndo: false)
        } catch {
            onCancel()
        }
    }

    /// 将 AppKit 左下原点的全局矩形转换成 CaptureFeature 约定的显示器内左上原点坐标。
    /// 所有坐标翻转集中在这里，类似 Java 项目中的 Adapter，UI 层不直接拼装裁剪坐标。
    func makeSelection(globalRect: CGRect) -> ScreenSelection {
        let target = frozenFrame.target
        let clipped = globalRect.standardized.intersection(target.globalRect)
        let localBottomY = clipped.minY - target.globalRect.minY
        let rectInDisplay = CGRect(
            x: clipped.minX - target.globalRect.minX,
            y: target.globalRect.height - localBottomY - clipped.height,
            width: clipped.width,
            height: clipped.height
        )
        return ScreenSelection(
            displayID: target.displayID,
            windowID: nil,
            rectInDisplay: rectInDisplay,
            displayScale: target.displayScale,
            globalRect: clipped
        )
    }

    /// 类似 Vue onUnmounted：先标记会话关闭并取消 Task，再移除监听、子窗口和视图引用。
    /// ARC 不能自动移除事件监听或终止任务，必须与创建路径对称清理。
    func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        colorPickerMagnifierController?.dismiss()
        colorPickerMagnifierController = nil
        operations.cancel()
        overlaySession.close()
        if let keyboardMonitor {
            NSEvent.removeMonitor(keyboardMonitor)
            self.keyboardMonitor = nil
        }

        toolbarController?.dismiss()
        toolbarController = nil

        // orderOut 只把窗口移出屏幕，不销毁对象；若还持有 contentView 或控制器，相关资源仍然存在。
        canvasPanel?.orderOut(nil)
        canvasPanel?.contentView = nil
        canvasPanel?.close()
        canvasPanel = nil
        canvasContentView = nil

        onClose?(documentID)
        onClose = nil
    }

    private func copySampledColor(format: ColorFormat) {
        guard let color = session.sampledColor else { return }
        guard onCopyColor(color, format) else { return }
    }


    @discardableResult
    /// 读取 OCR 连续选择生成的文本，再调用注入的复制接口；返回 Bool 供按键路径决定是否已处理。
    func copySelectedOCRText() -> Bool {
        guard !session.isProcessing, let text = session.selectedOCRText else { return false }
        do {
            try onCopyText(text)
            session.errorMessage = nil
            return true
        } catch {
            session.errorMessage = error.localizedDescription
            return false
        }
    }

    private func performExport(_ target: EditorExportTarget) {
        operations.performExport(target) { [weak self] result in
            guard let self, !isDismissed else { return }
            onExport(result, selection.globalRect)
        }
    }

    @discardableResult
    /// 按钮与快捷键共用的动作分发器；先处理取消/忙碌/文本草稿，再执行选工具或异步命令。
    func performToolbarAction(_ action: ScreenshotToolbarAction) -> Bool {
        defer { colorPickerMagnifierController?.refresh() }
        if case .cancel = action {
            onCancel()
            return true
        }
        guard !session.isProcessing else { return false }
        session.errorMessage = nil

        if case .undo = action {
            session.document.undo()
            return true
        }
        if case .redo = action {
            session.document.redo()
            return true
        }

        // 当前文本输入框不是文档操作；离开文本工具或执行完成类命令前先提交，
        // 确保用户刚输入的内容会进入撤销栈并出现在最终导出图片中。
        if case .selectTool(.text) = action {
            // 再次选择文本工具时保留当前输入光标。
        } else {
            session.commitTextEntry()
        }

        switch action {
        case let .selectTool(tool):
            session.showsTranslationOptions = false
            session.clearOCRRegions()
            session.cancelDraft()
            session.document.selectedTool = tool
            return confirmSelectionForEditing(revealsStylePanel: true)

        case .smartRedaction:
            session.showsTranslationOptions = false
            session.clearOCRRegions()
            session.cancelDraft()
            session.document.selectedTool = .redaction
            guard confirmSelectionForEditing(revealsStylePanel: true) else { return false }
            if !session.hasRequestedAutomaticRedaction {
                session.hasRequestedAutomaticRedaction = true
                operations.performSmartRedaction()
            }

        case .ocr:
            session.showsTranslationOptions = false
            guard confirmSelectionForEditing(revealsStylePanel: false) else { return false }
            toolbarController?.hideStylePanel()
            operations.performOCR()

        case .translation:
            session.clearOCRRegions()
            session.cancelDraft()
            session.showsTranslationOptions = true
            guard confirmSelectionForEditing(revealsStylePanel: true) else { return false }
            // 首次使用初始化时传入的截图语言组合；再次点击使用本会话当前选择。
            // 不依赖副工具栏的异步语言列表加载，点击工具即发起一次翻译。
            operations.performTranslation()

        case .startTranslation:
            guard session.showsTranslationOptions else { return false }
            guard confirmSelectionForEditing(revealsStylePanel: false) else { return false }
            operations.performTranslation()

        case .pin:
            guard confirmSelectionForEditing(revealsStylePanel: false) else { return false }
            performExport(.pin)

        case .copyFile:
            guard confirmSelectionForEditing(revealsStylePanel: false) else { return false }
            performExport(.fileClipboard)

        case .copy:
            guard confirmSelectionForEditing(revealsStylePanel: false) else { return false }
            performExport(.imageClipboard)

        case let .copySampledColor(format):
            copySampledColor(format: format)

        case .undo, .redo, .cancel:
            return true
        }
        return true
    }
}

private extension InlineScreenshotController {
    /// SwiftUI 的 HostingView、TextField、ColorPicker 都可能先消费 Esc，导致事件无法
    /// 继续冒泡到 NSPanel.keyDown。Local Monitor 在 AppKit 分发事件之前执行，因此能
    /// 为整个编辑会话提供稳定的 Esc 语义。
    func installKeyboardMonitor() {
        guard keyboardMonitor == nil else { return }
        // local monitor 在本应用派发事件前执行；返回 nil 消费事件，返回 event 才继续交给 responder chain。
        keyboardMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !self.isDismissed else { return event }

            // 应用可能同时保留多个编辑/贴图窗口。只处理属于当前编辑会话的窗口，
            // 避免一个 Esc 关闭错误的会话。
            let eventWindow = event.window ?? NSApp.keyWindow
            guard self.owns(window: eventWindow) else { return event }

            if event.keyCode == 53 {
                self.onCancel()
                return nil // nil 表示 Esc 已消费，不再交给 TextField 等子控件。
            }

            let shortcutFlags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if !event.isARepeat,
               event.keyCode == 0,
               shortcutFlags == .command,
               self.session.isOCRMode {
                self.session.selectAllOCRText()
                return nil
            }
            if !event.isARepeat,
               event.keyCode == 8,
               shortcutFlags == .command,
               self.session.isOCRMode,
               self.session.selectedOCRCharacterCount > 0 {
                // OCR 文字选区完成后，Cmd+C 只属于文字复制。即使写入剪贴板失败，
                // 也不能继续向后分发给取色或其他可配置快捷键。
                _ = self.copySelectedOCRText()
                return nil
            }

            if !event.isARepeat,
               (event.keyCode == 36 || event.keyCode == 76),
               shortcutFlags.isEmpty {
                // 回车属于截图会话的“完成并复制”，不能被 NSTextView 写成换行，
                // 也不再作为单独的“固定本段文字”命令。
                _ = self.performToolbarAction(.copy)
                return nil
            }

            // 编辑文字时，裸按键及原生撤销/重做继续交给输入框。
            if eventWindow?.firstResponder is NSTextView,
               shortcutFlags.isEmpty || (event.keyCode == 6 && (shortcutFlags == .command || shortcutFlags == [.command, .shift])) {
                return event
            }
            guard !event.isARepeat,
                  let action = self.toolShortcutAction(matching: event) else {
                return event
            }
            if eventWindow?.firstResponder is NSTextView, action == .undo || action == .redo {
                return event
            }
            guard self.performToolShortcut(action) else {
                return event
            }
            return nil
        }
    }

    /// 把 NSEvent 键码与有效修饰键转换为项目描述，再与本会话加载的快捷键表匹配。
    private func toolShortcutAction(matching event: NSEvent) -> ScreenshotToolShortcutAction? {
        var modifiers: Set<HotKeyModifier> = []
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let descriptor = HotKeyDescriptor(keyCode: UInt32(event.keyCode), modifiers: modifiers)
        return toolShortcuts.first(where: { $0.value == descriptor })?.key
    }

    @discardableResult
    /// 将快捷动作归入工具栏的统一执行入口，撤销/重做先检查处理状态与历史是否可用。
    private func performToolShortcut(_ action: ScreenshotToolShortcutAction) -> Bool {
        switch action {
        case .ocr:
            return performToolbarAction(.ocr)
        case .translation:
            return performToolbarAction(.translation)
        case .redaction:
            return performToolbarAction(.smartRedaction)
        case .pin:
            return performToolbarAction(.pin)
        case .copyFile:
            return performToolbarAction(.copyFile)
        case .cancel:
            return performToolbarAction(.cancel)
        case .copy:
            return performToolbarAction(.copy)
        case .undo:
            guard !session.isProcessing, session.document.canUndo else { return false }
            session.document.undo()
            return true
        case .redo:
            guard !session.isProcessing, session.document.canRedo else { return false }
            session.document.redo()
            return true
        case .rectangle, .arrow, .pen, .text, .step, .colorPicker:
            guard let tool = action.editorTool else { return false }
            return performToolbarAction(.selectTool(tool))
        }
    }

    /// 通过 === 比较窗口实例身份；同样尺寸或标题的其他窗口也不能接收当前会话快捷动作。
    private func owns(window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === canvasPanel || toolbarController?.owns(window: window) == true { return true }
        return overlaySession.owns(window: window)
    }
}

private extension InlineScreenshotController {
    /// 初始阶段由原来的选区 View 接收鼠标，画布只占位但不参与 hit-test。
    /// Java 对照：相当于 CardLayout 当前显示 ADJUST_SELECTION 卡片，工具栏独立可用；
    /// 只有选择绘图工具后才切到 EDIT_IMAGE 卡片。
    func focusSelectionAdjustment() {
        guard session.isAdjustingSelection else { return }
        overlaySession.focusSelectionAdjustment()
    }

    /// 点击子窗口工具栏后，AppKit 会把 key window 留在工具栏上。若不主动归还焦点，
    /// 用户下一次点击画布只是在激活画布窗口，真正的 DragGesture 要第二次才收到。
    func focusCanvas() {
        canvasPanel?.makeKey()
        // 显式设置 First Responder，作用类似 Swing 的 requestFocusInWindow()。
        canvasPanel?.makeFirstResponder(canvasContentView)
        // 工具按钮在另一个 NSPanel 中，切回画布时主动刷新一次，避免沿用按钮的小手光标。
        canvasContentView?.refreshCursor()
    }

    /// 拖动过程中只搬动轻量 NSPanel 和工具栏，不修改 ImageDocument 的 Retina 位图。
    func updateSelectionLayout(globalRect: CGRect) {
        selection = makeSelection(globalRect: globalRect)
        layoutCanvasPanel()
        toolbarController?.updateSelectionFrame(selection.globalRect)
    }

    /// NSWindow 外框使用整数点；内部画布保留 Retina 半点边界，不能铺满取整后的窗口。
    private func layoutCanvasPanel() {
        guard let panel = canvasPanel, let hostingView = canvasContentView,
              let container = panel.contentView else { return }
        panel.setFrame(selection.globalRect.integral, display: false)
        // 将 AppKit 屏幕全局坐标转到窗口坐标；还需 View.convert 才能进入具体视图的局部空间。
        let rectInWindow = panel.convertFromScreen(selection.globalRect)
        // 坐标转换中的 nil 表示所属窗口坐标系，不表示屏幕坐标；跨到屏幕还需窗口转换 API。
        hostingView.frame = container.convert(rectInWindow, from: nil)
    }

    func showBackdropPanels() {
        // 正常截图流程直接接管选择阶段仍在屏幕上的 NSPanel。窗口对象和遮罩像素都
        // 保持连续，交互切换为选区调整或外部取消，减少窗口销毁重建造成的视觉跳变。
        overlaySession.show(
            onSelectionChanged: { [weak self] globalRect in
                self?.updateSelectionLayout(globalRect: globalRect)
            },
            onSelectionChangeEnded: { [weak self] globalRect in
                self?.finishSelectionAdjustment(globalRect: globalRect)
            },
            onCancel: onCancel
        )
    }

    func showCanvasPanel() {
        let panel = ScreenshotOverlayPanel(
            contentRect: selection.globalRect.integral,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // level 决定窗口相对其他层级的前后位置；同层窗口的顺序还由 orderFront/子窗口关系决定。
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        // 首帧 SwiftUI Canvas 尚未绘制完成时保持透明，让下方原屏幕内容继续可见；
        // 不能使用黑色不透明底，否则快速截图时会短暂暴露一帧黑色矩形。
        panel.isOpaque = false
        // 将窗口/图层底色设为透明；最终是否透出下层还取决于内容视图和 isOpaque 的配置。
        panel.backgroundColor = .clear
        // 这是系统窗口阴影开关；SwiftUI 内容若自己绘阴影，两者叠加可能出现双重边缘。
        panel.hasShadow = false
        // 设置 AppKit 的窗口共享策略；它不是对所有屏幕捕获方式都有效的像素保密保证。
        panel.sharingType = .none
        // 指定系统对窗口显示/隐藏采用的动画行为；与内容图层 CABasicAnimation 是不同层面的动画。
        panel.animationBehavior = .none
        // 控制窗口在 Spaces 与全屏空间中的参与方式；不是 SwiftUI 中的子视图布局属性。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onEscape = onCancel
        // NSHostingView 是 AppKit/SwiftUI 桥：外层仍由 NSPanel 控制窗口层级，
        // 内部画布使用 SwiftUI 的声明式状态刷新。
        let hostingView = EditorFirstMouseHostingView(
            rootView: InlineEditorCanvas(
                session: session,
                onCancel: onCancel,
                translationClient: translationClient
            ),
            cursorSession: session.cursorSession,
            cursorContext: { [weak self] point in
                guard let self, !self.isDismissed, let canvasView = self.canvasContentView else { return .outside }
                // NSHostingView 的本地坐标转换为左上原点后交给会话做文字命中。
                let location = CGPoint(
                    x: point.x,
                    y: canvasView.isFlipped ? point.y : canvasView.bounds.height - point.y
                )
                return self.session.cursorContext(at: location, canvasSize: canvasView.bounds.size)
            },
            defaultCursorContext: { [weak self] in
                guard let self, !self.isDismissed else { return .outside }
                return self.session.defaultCursorContext()
            }
        )
        // 控制 HostingView 是否向 AppKit 提供 SwiftUI 的固有/最小/最大尺寸；窗口尺寸由外层管理时可关闭反向影响。
        hostingView.sizingOptions = []
        // AppKit 旧式自动尺寸规则，按父视图尺寸变化伸缩；不是 SwiftUI 的状态属性，也不是完整 Auto Layout 约束。
        hostingView.autoresizingMask = []
        // 调整选区时画布不可见且完全穿透鼠标，事件继续交给下方 SelectionOverlayView。
        // 工具栏是独立子窗口，不受这个开关影响，仍可立即点击。
        hostingView.isHidden = true
        let container = NSView(frame: CGRect(origin: .zero, size: panel.frame.size))
        panel.contentView = container
        container.addSubview(hostingView)
        canvasPanel = panel
        canvasContentView = hostingView
        layoutCanvasPanel()
        // 不在 orderFront 之前做同步 display。SwiftUI 的 Canvas 首帧绘制在窗口尚未
        // 上屏（windowNumber 未分配）、应用又是 .accessory 未激活 + screenSaver 层级
        // 面板时，会在主线程同步阻塞，表现为彩虹圈、工具栏不出现。面板背景已设为
        // 透明，首帧延迟只会保持透明而不会闪黑，交由 AppKit 在上屏后异步渲染。
        panel.orderFrontRegardless()
        // 控制整个窗口是否接收鼠标；设为 true 时事件可落到下层窗口，不能把它当作阻止点击穿透。
        panel.ignoresMouseEvents = true
    }

    func showToolbarPanel() {
        guard let canvasPanel else { return }
        let controller = ScreenshotToolbarPanelController(
            session: session,
            shortcuts: toolShortcuts,
            onAction: { [weak self] action in
                _ = self?.performToolbarAction(action)
            },
            onCancel: onCancel
        )
        toolbarController = controller
        controller.show(attachedTo: canvasPanel, selectionFrame: selection.globalRect)
    }
}
