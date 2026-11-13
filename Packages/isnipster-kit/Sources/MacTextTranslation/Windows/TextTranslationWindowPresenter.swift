import MacShared
import MacPreferences
import MacTranslation
// 阅读路线
// 管理翻译窗口显示、置顶、位置/尺寸、原应用恢复和宿主模型的生命周期。
// SwiftUI 回传内容高度后由这里 setFrame；窗口持有 HostingView，HostingView 才承载声明式页面。
// 官方参考（NSWindow 窗口坐标与焦点）：https://developer.apple.com/documentation/appkit/nswindow

import AppKit
import AVFoundation
import ClipboardFeature
import NaturalLanguage
import Observation
import TextTranslationFeature
import iSnipsterCore
import SwiftUI

/// 独立文本翻译窗口。TranslationSession 仍由可见 SwiftUI View 提供，窗口关闭即取消任务。
@MainActor
public final class TextTranslationWindowPresenter {
    private let preferencesStore: any TranslationPreferencesStoring
    private let translationClient: AppleTranslationClient
    private let translationService: any TextTranslationServicing
    private let clipboardWriter: any ClipboardWriting
    private var panel: TextTranslationPanel?
    private var model: TextTranslationModel?

    public init(
        translationClient: AppleTranslationClient,
        translationService: any TextTranslationServicing,
        clipboardWriter: any ClipboardWriting,
        preferencesStore: any TranslationPreferencesStoring
    ) {
        self.preferencesStore = preferencesStore
        self.translationClient = translationClient
        self.translationService = translationService
        self.clipboardWriter = clipboardWriter
    }

    /// 快捷键只关闭正在交互的翻译窗口；被遮挡或失焦的窗口应重新置前。
    public func toggle(
        targetLanguage: String,
        onTargetLanguageChange: @escaping @MainActor (String) -> Void
    ) {
        if NSApp.isActive, panel?.isVisible == true, panel?.isKeyWindow == true {
            dismiss()
            return
        }
        show(targetLanguage: targetLanguage, onTargetLanguageChange: onTargetLanguageChange)
    }

    /// 菜单的“翻译”始终打开窗口，复用已有输入、结果和进行中的请求。
    public func show(
        targetLanguage: String,
        onTargetLanguageChange: @escaping @MainActor (String) -> Void
    ) {
        if let panel {
            updateTargetLanguage(targetLanguage)
            bringToFront(panel)
            return
        }

        let model = TextTranslationModel(
            sourceText: "",
            targetLanguage: targetLanguage,
            service: translationService,
            clipboardWriter: clipboardWriter,
            preferencesStore: preferencesStore,
            onTargetLanguageChange: onTargetLanguageChange
        )
        let initiallyPinned = TextTranslationWindowPinStore.load()
        let storedFrame = TextTranslationWindowPlacementStore.load()
        let initialFrame = storedFrame ?? TextTranslationWindowSizing.defaultFrame()
        let panel = TextTranslationPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        let rootView = TextTranslationView(
            model: model,
            translationClient: translationClient,
            initiallyPinned: initiallyPinned,
            onPinChange: { [weak self] isPinned in
                self?.setPinned(isPinned)
            },
            onWindowDragEnd: { [weak self] in
                self?.panel?.finishWindowDrag()
            },
            onPreferredHeightChange: { [weak panel] height in
                panel?.updatePreferredContentHeight(height)
            },
            maximumWindowHeight: { [weak panel] in
                TextTranslationWindowSizing.maximumSize(for: panel?.screen).height
            },
            onClose: { [weak self] in self?.dismiss() }
        )
        panel.title = AppText.text("文本翻译")
        panel.isMovableByWindowBackground = false
        // isOpaque 是给合成器的“不透明”声明，不是设置颜色；透明窗口还要使用透明 backgroundColor。
        panel.isOpaque = false
        // 将窗口/图层底色设为透明；最终是否透出下层还取决于内容视图和 isOpaque 的配置。
        panel.backgroundColor = .clear
        // 这是系统窗口阴影开关；SwiftUI 内容若自己绘阴影，两者叠加可能出现双重边缘。
        panel.hasShadow = true
        panel.isFloatingPanel = initiallyPinned
        // 决定应用失去激活状态时是否自动隐藏面板；隐藏不等于关闭，也不会自动释放会话状态。
        panel.hidesOnDeactivate = !initiallyPinned
        panel.minSize = TextTranslationWindowSizing.minimumSize
        panel.contentResizeIncrements = NSSize(width: 1, height: 1)
        // level 决定窗口相对其他层级的前后位置；同层窗口的顺序还由 orderFront/子窗口关系决定。
        panel.level = initiallyPinned ? .floating : .normal
        // 控制窗口在 Spaces 与全屏空间中的参与方式；不是 SwiftUI 中的子视图布局属性。
        panel.collectionBehavior = initiallyPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
        panel.delegate = panel
        panel.onTranslate = { [weak model] in
            guard let model, !model.isTranslating else { return }
            model.translate()
        }
        panel.onClose = { [weak self, weak panel] in
            guard let self, self.panel === panel else { return }
            self.model?.cancel()
            self.model = nil
            self.panel = nil
        }

        // NSHostingView 是 SwiftUI → AppKit 的桥：rootView 描述内容，NSView/NSWindow 仍负责原生层级。
        let hostingView = NSHostingView(rootView: rootView)
        // 控制 HostingView 是否向 AppKit 提供 SwiftUI 的固有/最小/最大尺寸；窗口尺寸由外层管理时可关闭反向影响。
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: panel.frame.size)
        // AppKit 旧式自动尺寸规则，按父视图尺寸变化伸缩；不是 SwiftUI 的状态属性，也不是完整 Auto Layout 约束。
        hostingView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        // 让 NSView 使用 backing layer，后续才能设置 CALayer 的圆角、内容与路径；视图和图层仍是两套对象。
        hostingView.wantsLayer = true

        // Liquid Glass 在实时缩放时使用独立的合成层，单靠 SwiftUI 的 clipShape
        // 可能在较小尺寸下短暂越过圆角。由 AppKit 容器再做一次同形状裁剪，
        // 确保窗口缩放到任意允许尺寸后仍保持连续圆角。
        let clippingView = NSView(frame: NSRect(origin: .zero, size: panel.frame.size))
        clippingView.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        clippingView.wantsLayer = true
        // 裁掉超出图层边界的内容；若阴影画在同一层，也可能被一起裁掉。
        clippingView.layer?.masksToBounds = true
        clippingView.layer?.cornerRadius = 24
        clippingView.layer?.cornerCurve = .continuous
        clippingView.addSubview(hostingView)
        panel.contentView = clippingView

        self.model = model
        self.panel = panel
        panel.restoreFrame(initialFrame)
        if storedFrame == nil {
            panel.center()
        }
        panel.onFrameChange = { frame in
            TextTranslationWindowPlacementStore.save(frame)
        }
        bringToFront(panel)
    }

    /// 同步设置选择；进行中的任务已保存参数快照，不重启请求、不清空结果。
    public func updateTargetLanguage(_ language: String) {
        guard let model, model.targetLanguage != language else { return }
        model.targetLanguage = language
    }

    private func bringToFront(_ panel: TextTranslationPanel) {
        // 等菜单点击事件完成后再交接焦点，避免菜单关闭过程干扰新窗口激活。
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self, let panel, self.panel === panel else { return }
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // 置顶同时影响层级、失活隐藏和 Space 行为；只改一个 Bool 不足以实现完整窗口行为。
    private func setPinned(_ isPinned: Bool) {
        guard let panel else { return }
        panel.isFloatingPanel = isPinned
        panel.hidesOnDeactivate = !isPinned
        panel.level = isPinned ? .floating : .normal
        panel.collectionBehavior = isPinned
            ? [.canJoinAllSpaces, .fullScreenAuxiliary]
            : [.fullScreenAuxiliary]
        TextTranslationWindowPinStore.save(isPinned)
        // 把窗口放到前面显示，不等于激活整个应用或把某个输入控件设为 first responder。
        panel.orderFrontRegardless()
    }

    public func dismiss() {
        model?.cancel()
        model = nil
        guard let panel else { return }
        TextTranslationWindowPlacementStore.save(panel.frame)
        panel.onClose = nil
        // orderOut 只把窗口移出屏幕，不销毁对象；若还持有 contentView 或控制器，相关资源仍然存在。
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
    }
}

@MainActor
/// 文本翻译专用浮动面板，负责窗口事件、尺寸和位置回调。
private final class TextTranslationPanel: NSPanel, NSWindowDelegate {
    var onClose: (() -> Void)?
    var onFrameChange: ((NSRect) -> Void)?
    var onTranslate: (() -> Void)?
    private var isApplyingEdgeSnap = false
    private var isUpdatingFrameInternally = false
    private var preferredContentHeight: CGFloat?

    // key window 是接收键盘的窗口；它与应用是否前台激活、窗口是否可见是不同状态。
    override var canBecomeKey: Bool { true }
    // main window 表示应用的主要文档窗口；工具面板可以接收键盘却不作为 main window。
    override var canBecomeMain: Bool { true }

    override func sendEvent(_ event: NSEvent) {
        if shouldTranslate(with: event) {
            onTranslate?()
            return
        }
        super.sendEvent(event)
    }

    override func close() {
        let action = onClose
        onClose = nil
        onTranslate = nil
        super.close()
        action?()
    }

    // 用户移动窗口后保存位置并按当前屏幕约束高度；内部布局引发的通知由标记过滤，避免回调递归。
    func windowDidMove(_ notification: Notification) {
        guard !isApplyingEdgeSnap, !isUpdatingFrameInternally else { return }
        onFrameChange?(frame)
        fitToPreferredContentHeight()
    }

    // 窗口宽度改变会影响文字换行；按内容高度重新适配，但内部 setFrame 不能再次触发同一更新链。
    func windowDidResize(_ notification: Notification) {
        guard !isApplyingEdgeSnap, !isUpdatingFrameInternally else { return }
        onFrameChange?(frame)
        fitToPreferredContentHeight()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        fitToPreferredContentHeight()
        onFrameChange?(frame)
    }

    func finishWindowDrag() {
        snapToVisibleScreenEdge()
        onFrameChange?(frame)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        return NSSize(
            width: max(frameSize.width, minSize.width),
            height: max(frameSize.height, minSize.height)
        )
    }

    /// Easydict 的窗口高度始终追随内容，用户拖动只决定宽度；内容过高时由结果区滚动。
    /// 调整高度时固定窗口顶部，避免查询结果返回后窗口在屏幕上上下跳动。
    func updatePreferredContentHeight(_ height: CGFloat) {
        guard height.isFinite, height > 0 else { return }
        preferredContentHeight = ceil(height)
        fitToPreferredContentHeight()
    }

    // 恢复上次保存位置前先裁到当前屏幕可用范围；外接显示器断开后旧坐标未必仍能看见。
    func restoreFrame(_ restoredFrame: NSRect) {
        let screen = screenForFrame(restoredFrame)
        let safeFrame = TextTranslationWindowSizing.safeFrame(
            restoredFrame,
            in: screen?.visibleFrame
        )
        isUpdatingFrameInternally = true
        setFrame(safeFrame, display: false)
        isUpdatingFrameInternally = false
    }

    // 裸回车才触发翻译；按键重复、带修饰键或输入法组合文本期间，都保留原生输入语义。
    private func shouldTranslate(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              !event.isARepeat,
              event.keyCode == 36 || event.keyCode == 76 else {
            return false
        }
        let modifiers = event.modifierFlags.intersection([
            .command,
            .control,
            .option,
            .shift,
        ])
        guard modifiers.isEmpty else { return false }
        if let textView = firstResponder as? NSTextView,
           // 输入法有尚未确认的组合文本时，回车应先确认候选词；不能直接当成提交/翻译快捷键。
           textView.hasMarkedText() {
            return false
        }
        return true
    }

    /// 吸附使用 visibleFrame，排除菜单栏/Dock占用区域；threshold 控制接近边缘多远才吸附。
    /// isApplyingEdgeSnap 防止 setFrameOrigin 引发的移动回调递归进入自身。
    private func snapToVisibleScreenEdge() {
        guard let targetScreen = screen ?? screenWithLargestIntersection() else { return }
        let bounds = targetScreen.visibleFrame
        let threshold: CGFloat = 22
        let visualInset: CGFloat = 0
        var origin = frame.origin

        if abs(frame.minX + visualInset - bounds.minX) <= threshold {
            origin.x = bounds.minX - visualInset
        } else if abs(frame.maxX - visualInset - bounds.maxX) <= threshold {
            origin.x = bounds.maxX - frame.width + visualInset
        }

        if abs(frame.minY + visualInset - bounds.minY) <= threshold {
            origin.y = bounds.minY - visualInset
        } else if abs(frame.maxY - visualInset - bounds.maxY) <= threshold {
            origin.y = bounds.maxY - frame.height + visualInset
        }

        guard origin != frame.origin else { return }
        isApplyingEdgeSnap = true
        setFrameOrigin(origin)
        isApplyingEdgeSnap = false
    }

    private func fitToPreferredContentHeight() {
        guard !isUpdatingFrameInternally,
              let preferredContentHeight else { return }

        let targetScreen = screen ?? screenWithLargestIntersection() ?? NSScreen.main
        let maximumSize = TextTranslationWindowSizing.maximumSize(for: targetScreen)
        let targetHeight = min(
            max(preferredContentHeight, minSize.height),
            maximumSize.height
        )
        guard abs(frame.height - targetHeight) > TextTranslationWindowSizing.geometryTolerance else {
            return
        }

        let currentTop = frame.maxY
        let proposedFrame = NSRect(
            x: frame.minX,
            y: currentTop - targetHeight,
            width: frame.width,
            height: targetHeight
        )
        let safeFrame = TextTranslationWindowSizing.safeFrame(
            proposedFrame,
            in: targetScreen?.visibleFrame
        )

        isUpdatingFrameInternally = true
        setFrame(safeFrame, display: true)
        isUpdatingFrameInternally = false
        onFrameChange?(frame)
    }

    private func screenForFrame(_ candidate: NSRect) -> NSScreen? {
        NSScreen.screens.max {
            NSIntersectionRect(candidate, $0.visibleFrame).width
                * NSIntersectionRect(candidate, $0.visibleFrame).height
                < NSIntersectionRect(candidate, $1.visibleFrame).width
                * NSIntersectionRect(candidate, $1.visibleFrame).height
        }
    }

    private func screenWithLargestIntersection() -> NSScreen? {
        NSScreen.screens.max {
            NSIntersectionRect(frame, $0.visibleFrame).width
                * NSIntersectionRect(frame, $0.visibleFrame).height
                < NSIntersectionRect(frame, $1.visibleFrame).width
                * NSIntersectionRect(frame, $1.visibleFrame).height
        }
    }
}

/// 集中定义文本翻译窗口的尺寸限制与内容高度换算规则。
private enum TextTranslationWindowSizing {
    static let minimumSize = NSSize(width: 360, height: 40)
    static let geometryTolerance: CGFloat = 0.5

    static func defaultFrame() -> NSRect {
        let screen = NSScreen.main
        let screenWidth = screen?.frame.width ?? 1727
        let scaledWidth = 440 * (1727 / screenWidth)
        let width = max(minimumSize.width, scaledWidth)
        return NSRect(origin: .zero, size: NSSize(width: width, height: minimumSize.height))
    }

    static func maximumSize(for screen: NSScreen?) -> NSSize {
        (screen ?? NSScreen.main)?.visibleFrame.size
            ?? NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
    }

    /// Easydict 只把窗口挪回当前屏幕安全区，不限制用户可拖出的最大宽度。
    static func safeFrame(_ frame: NSRect, in visibleFrame: NSRect?) -> NSRect {
        guard let visibleFrame else { return frame }

        var x = frame.minX
        var y = frame.minY
        if x < visibleFrame.minX {
            x = visibleFrame.minX
        }
        if x + frame.width > visibleFrame.maxX {
            x = visibleFrame.maxX - frame.width
        }
        if y + frame.height > visibleFrame.maxY {
            y = visibleFrame.maxY - frame.height
        }
        if y < visibleFrame.minY, frame.height <= visibleFrame.height {
            y = visibleFrame.minY
        }
        return NSRect(origin: NSPoint(x: x, y: y), size: frame.size)
    }
}

/// 持久化文本翻译窗口上次使用的位置。
private enum TextTranslationWindowPlacementStore {
    private static let key = "isnipster.textTranslationWindowFrame.v5"

    static func load() -> NSRect? {
        guard let value = UserDefaults.standard.string(forKey: key) else { return nil }
        let frame = NSRectFromString(value)
        guard frame.width >= TextTranslationWindowSizing.minimumSize.width,
              frame.height >= TextTranslationWindowSizing.minimumSize.height,
              NSScreen.screens.contains(where: {
                  NSIntersectionRect(frame, $0.visibleFrame).width >= 100
                      && NSIntersectionRect(frame, $0.visibleFrame).height
                          >= TextTranslationWindowSizing.minimumSize.height
              }) else {
            return nil
        }
        return frame
    }

    static func save(_ frame: NSRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: key)
    }
}

/// 持久化文本翻译窗口是否置顶的用户选择。
private enum TextTranslationWindowPinStore {
    private static let key = "isnipster.textTranslationWindowPinned.v1"

    static func load() -> Bool {
        UserDefaults.standard.bool(forKey: key)
    }

    static func save(_ isPinned: Bool) {
        UserDefaults.standard.set(isPinned, forKey: key)
    }
}
