import MacShared
import MacScreenshotSupport
import MacTranslation
import RecognitionFeature
// 阅读路线
// 为每张截图创建文档、命令服务与控制器，保留会话引用并在关闭后释放。
// 复制/文件复制/贴图是不同输出路径；渲染可共享，但最终落点和窗口收尾不同。
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

/// 截图编辑浮层的生命周期管理器。
/// 截图完成后不再创建传统标题栏窗口，而是把编辑画布覆盖回原选区，并把工具栏
/// 放在选区下方。关闭浮层时取消任务并断开窗口/视图引用；仍在结束的异步任务退出后释放最后的图片引用。

@MainActor
public final class ImageEditorPresenter {
    private let exportService: EditorExportService
    private let translationTimeout: @MainActor () -> Int
    private let translationClient: AppleTranslationClient
    private let commands: ImageEditorCommands
    private let clipboardWriter: any ClipboardWriting
    private let overlays: any ScreenshotOverlayProviding
    private let preferencesStore: any EditorPreferencesStoring
    /// Presenter 只缓存很小的配置 DTO，让同一进程内下一次截图无需再次解码 UserDefaults。
    private var editorPreferences: EditorPreferences
    private var editors: [UUID: InlineScreenshotController] = [:]
    private var pins: [UUID: NSPanel] = [:]
    /// 最后一个编辑会话结束（复制 / 取消 / 贴图）时回调，让 AppModel 释放 Esc 并恢复剪贴板面板行为。
    /// 由 AppModel 注入，闭包必须弱引用注入方，避免长生命周期环。
    public var onSessionEnd: (@MainActor () -> Void)?

    public init(
        renderer: any ImageRendering,
        recognizer: any TextRecognizing,
        translationClient: AppleTranslationClient,
        translationPipeline: ImageTranslationPipeline,
        clipboardWriter: any ClipboardWriting,
        overlays: any ScreenshotOverlayProviding,
        preferencesStore: any EditorPreferencesStoring,
        translationTimeout: @escaping @MainActor () -> Int
    ) {
        self.translationTimeout = translationTimeout
        self.exportService = EditorExportService(renderer: renderer, clipboardWriter: clipboardWriter)
        self.translationClient = translationClient
        commands = ImageEditorCommands(
            renderer: renderer, recognizer: recognizer,
            translationPipeline: translationPipeline
        )
        self.clipboardWriter = clipboardWriter
        self.overlays = overlays
        self.preferencesStore = preferencesStore
        editorPreferences = preferencesStore.load()
    }

    /// 在原截图位置进入就地编辑，不出现普通应用窗口。
    public func present(
        image: RasterImage,
        selection: ScreenSelection,
        frozenFrame: FrozenScreenFrame,
        translationLanguages: TranslationLanguagePair
    ) {
        guard editors.isEmpty else {
            presentError(AppFailure.unavailable(AppText.text("请先完成当前截图编辑")))
            return
        }
        // 每次截图仍创建独立 Document，不共享原图或撤销栈；只有工具栏配置作为值对象传入。
        // Document 修改配置时回传新的 DTO，Presenter 再交给 Repository 写入 UserDefaults。
        let document = ImageDocument(
            original: image,
            preferences: editorPreferences,
            onPreferencesChanged: { [weak self] preferences in
                guard let self else { return }
                self.editorPreferences = preferences
                self.preferencesStore.save(preferences)
            }
        )
        let controller = InlineScreenshotController(
            document: document,
            selection: selection,
            frozenFrame: frozenFrame,
            // Controller 强持有回调；回调必须弱引用 Presenter/Document，避免闭环。
            exportService: exportService,
            onExport: { [weak self] result, frame in
                self?.completeExport(result, documentID: document.id, frame: frame)
            },
            onOCR: { [weak self, weak document] in
                guard let self, let document else { throw AppFailure.cancelled }
                return try await self.commands.recognize(document: document)
            },
            onTranslate: { [weak self, weak document] sourceLanguage, targetLanguage in
                guard let self, let document else { throw AppFailure.cancelled }
                return try await self.commands.translate(
                    document: document,
                    sourceLanguage: sourceLanguage,
                    targetLanguage: targetLanguage,
                    fallback: ScreenshotTranslationFallback(languages: translationLanguages)
                )
            },
            onSmartRedaction: { [weak self, weak document] in
                guard let self, let document else { throw AppFailure.cancelled }
                return try await self.commands.smartRedaction(document: document)
            },
            onCopyColor: { [weak self] color, format in
                self?.copyColor(color, format: format) ?? false
            },
            onCopyText: { [weak self] text in
                guard let self else { throw AppFailure.cancelled }
                try self.clipboardWriter.writeAndRecord(.text(text))
            },
            onCancel: { [weak self] in
                self?.dismissEditor(id: document.id)
            },
            translationLanguages: translationLanguages,
            translationClient: translationClient,
            translationTimeout: translationTimeout,
            overlaySession: overlays.makeEditorSession(selection: selection, frozenFrame: frozenFrame)
        )
        controller.onClose = { [weak self] id in
            guard let self else { return }
            // 从字典移除是这个会话的生命周期终点，随后位图和 SwiftUI View 可释放。
            self.editors[id] = nil
            // 无编辑会话后通知应用层收尾；贴图窗口有独立生命周期，不阻止下一次截图。
            if self.editors.isEmpty {
                self.onSessionEnd?()
            }
        }
        editors[document.id] = controller
        controller.show()
    }

    /// 关闭全部编辑会话；再次按截图热键或按 Esc 时由 AppModel 调用。
    /// 先复制字典值再遍历，因为 dismiss 的回调会同步从 editors 中移除当前项。
    public func dismissAll() {
        Array(editors.values).forEach { $0.dismiss() }
    }

    /// 异步工作由会话完成；这里只在有效会话上创建贴图并关闭编辑窗口。
    private func completeExport(_ result: EditorExportResult, documentID: UUID, frame: CGRect) {
        guard editors[documentID] != nil else { return }
        if case let .pin(image) = result {
            let id = UUID()
            let panel = makePinPanel(image: image.cgImage, frame: frame) { [weak self] in
                self?.pins[id] = nil
            }
            pins[id] = panel
            panel.orderFrontRegardless()
        }
        dismissEditor(id: documentID)
    }

    private func dismissEditor(id: UUID) {
        editors[id]?.dismiss()
    }

    /// 编辑器取色只复制格式化后的颜色文本，不把任何截图像素写入历史或磁盘。
    private func copyColor(_ color: SampledColor, format: ColorFormat) -> Bool {
        do {
            try clipboardWriter.writeAndRecord(.color(color.formatted(as: format)))
            return true
        } catch {
            presentError(error)
            return false
        }
    }

    /// 使用最终选区的 AppKit 点坐标，避免把 Retina 像素尺寸当作窗口尺寸。
    private func makePinPanel(image: CGImage, frame: CGRect, onClose: @escaping () -> Void) -> NSPanel {
        let size = frame.size
        let panel = PinnedImagePanel(
            contentRect: frame,
            styleMask: [.borderless, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // level 决定窗口相对其他层级的前后位置；同层窗口的顺序还由 orderFront/子窗口关系决定。
        panel.level = .floating
        panel.isFloatingPanel = true
        // 控制窗口在 Spaces 与全屏空间中的参与方式；不是 SwiftUI 中的子视图布局属性。
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 决定应用失去激活状态时是否自动隐藏面板；隐藏不等于关闭，也不会自动释放会话状态。
        panel.hidesOnDeactivate = false
        // 关闭时是否自动释放是 AppKit 的窗口生命周期选项；控制器若要复用窗口，会显式保留并自行管理引用。
        panel.isReleasedWhenClosed = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = false
        // isOpaque 是给合成器的“不透明”声明，不是设置颜色；透明窗口还要使用透明 backgroundColor。
        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        // 指定系统对窗口显示/隐藏采用的动画行为；与内容图层 CABasicAnimation 是不同层面的动画。
        panel.animationBehavior = .none
        // 这是系统窗口阴影开关；SwiftUI 内容若自己绘阴影，两者叠加可能出现双重边缘。
        panel.hasShadow = true
        panel.contentAspectRatio = size
        panel.contentMinSize = CGSize(width: min(80, size.width), height: min(60, size.height))
        panel.onClose = onClose

        let view = PinImageView(frame: NSRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageFrameStyle = .none
        // AppKit 旧式自动尺寸规则，按父视图尺寸变化伸缩；不是 SwiftUI 的状态属性，也不是完整 Auto Layout 约束。
        view.autoresizingMask = [NSView.AutoresizingMask.width, NSView.AutoresizingMask.height]
        panel.contentView = view
        panel.setFrame(frame, display: false)
        return panel
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppText.text("操作失败")
        alert.informativeText = error.localizedDescription
        // 进入嵌套模态事件循环并等待结果；当前调用栈尚未返回，不能假定弹窗期间所有应用事件都停止。
        alert.runModal()
    }
}
