// 阅读路线
// 阅读顺序：先看 init 中每组依赖，再沿接口进入 Feature，最后看 MacPlatform 实现。
// 这里相当于手写 Spring @Configuration：构造一次的对象可被多个服务共享，局部变量离开 init 不代表对象立即释放。
// 官方参考（Swift 协议与抽象）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/

import CaptureFeature
import ClipboardFeature
import ImageEditorFeature
import ImageTranslationFeature
import MacPlatform
import TextTranslationFeature
import Foundation

/// 唯一的依赖组装入口。
///
/// Java 开发中可以把它理解为一个非常小的手写 DI Container。Feature 只依赖协议，
/// 具体的 AppKit/ScreenCaptureKit 实现全部在这里注入，避免隐式全局单例。
@MainActor
final class CompositionRoot {
    let clipboardController: ClipboardController
    let appModel: AppModel

    init() {
        let translationPreferences = UserDefaultsTranslationPreferencesStore()
        // 剪贴板模块：Client 隔离 NSPasteboard，Store 负责本地持久化历史。
        let pasteboardClient = MacPasteboardClient()
        let clipboardStore = ClipboardHistoryStore()
        let clipboardController = ClipboardController(
            client: pasteboardClient,
            store: clipboardStore,
            policyProvider: { AppPreferences.Clipboard.currentPolicy() }
        )
        self.clipboardController = clipboardController
        let clipboardWriter = ClipboardOutputService(controller: clipboardController, client: pasteboardClient)
        let clipboardPresenter = ClipboardWindowPresenter(controller: clipboardController, clipboardWriter: clipboardWriter, client: pasteboardClient)

        // 截图模块：AppKit 负责“选哪里”，ScreenCaptureKit 负责“读像素”。
        // 选择器和编辑器共享 OverlayCoordinator，把同一批遮罩窗口从选区阶段
        // 转移到编辑阶段，避免两个独立 NSPanel 集合之间发生非原子切换。
        let cursorController = ScreenshotCursorController()
        let overlayCoordinator = ScreenshotOverlayCoordinator(cursorController: cursorController)
        let selector = AppKitScreenRegionSelector(
            overlayCoordinator: overlayCoordinator,
            cursorController: cursorController,
            copyColor: { value in
                do {
                    try clipboardWriter.writeAndRecord(.color(value))
                    return true
                } catch {
                    return false
                }
            }
        )
        let screenCapturer = ScreenCaptureKitClient()
        let captureUseCase = CaptureUseCase(selector: selector, capturer: screenCapturer)

        // 图片翻译模块是一条管道：Vision OCR -> Apple Translation -> CoreGraphics 重绘。
        let textRecognizer = VisionTextRecognizer()
        let translationClient = AppleTranslationClient()
        let translationPipeline = ImageTranslationPipeline(
            recognizer: textRecognizer,
            translator: translationClient,
            renderer: CoreGraphicsTranslationRenderer()
        )

        // 编辑模块：绘制工具保存矢量命令；OCR/翻译作为异步命令复用同一个识别器。
        let imageRenderer = CoreGraphicsImageRenderer()
        // UserDefaults 只保存颜色、粗细和工具模式；编辑器的图片与文字内容不会传给它。
        let editorPreferencesStore = UserDefaultsEditorPreferencesStore()
        let editorPresenter = ImageEditorPresenter(
            renderer: imageRenderer,
            recognizer: textRecognizer,
            translationClient: translationClient,
            translationPipeline: translationPipeline,
            clipboardWriter: clipboardWriter,
            overlays: overlayCoordinator,
            preferencesStore: editorPreferencesStore,
            translationTimeout: { translationPreferences.load().screenshotTimeoutSeconds }
        )

        // 文本翻译使用独立 TranslationSession，避免与截图编辑器里的图片翻译互相抢占配置。
        let textTranslationClient = AppleTranslationClient()
        let translationService = TranslationRoutingService(apple: textTranslationClient, remote: RemoteTextTranslationClient())
        let textTranslationPresenter = TextTranslationWindowPresenter(
            translationClient: textTranslationClient,
            translationService: translationService,
            clipboardWriter: clipboardWriter,
            preferencesStore: translationPreferences
        )

        // AppModel 相当于面向 SwiftUI 的 ApplicationService / ViewModel，
        // 只负责编排用例与暴露 UI 状态，不直接实现平台细节。
        let hotKeys = CarbonHotKeyService()
        let captureWorkflow = CaptureWorkflowCoordinator(
            captureUseCase: captureUseCase,
            editorPresenter: editorPresenter,
            hotKeys: hotKeys,
            onBeginInteraction: { clipboardPresenter.suspendDismissalForCapture() },
            onEndInteraction: { clipboardPresenter.resumeDismissalAfterCapture() }
        )
        appModel = AppModel(
            captureWorkflow: captureWorkflow,
            clipboardController: clipboardController,
            clipboardPresenter: clipboardPresenter,
            textTranslationPresenter: textTranslationPresenter,
            hotKeys: hotKeys,
            translationPreferences: translationPreferences
        )
    }
}
