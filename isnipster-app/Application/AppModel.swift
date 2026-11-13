// 阅读路线
// 从 capture / showClipboard / showTextTranslation 看用户动作，再读 perform 的异步收尾。
// 可类比 Pinia store + Java Application Service：公开可观察状态，协调已注入的服务，不直接绘制界面。
// 官方参考（Observable 数据驱动界面）：https://developer.apple.com/documentation/swiftui/managing-model-data-in-your-app

import AppKit
import CaptureFeature
import ClipboardFeature
import ImageTranslationFeature
import MacPlatform
import Observation
import iSnipsterCore

/// 应用级状态和用户动作入口，协调截图、剪贴板、文本翻译与全局快捷键。
///
/// `@Observable` 是编译期宏：SwiftUI 读取到哪个属性，就自动订阅哪个属性，
/// 不需要手写 PropertyChangeSupport。`@MainActor` 保证状态修改都在 UI 隔离域。
@MainActor
@Observable
final class AppModel {
    private let translationPreferences: any TranslationPreferencesStoring
    private let captureWorkflow: CaptureWorkflowCoordinator
    let clipboardController: ClipboardController
    private let clipboardPresenter: ClipboardWindowPresenter
    private let textTranslationPresenter: TextTranslationWindowPresenter
    private let hotKeys: any GlobalHotKeyRegistering
    private(set) var shortcutDescriptors: [AppShortcutAction: HotKeyDescriptor]
    private(set) var shortcutConfigurationMessage: String?

    var isBusy: Bool { captureWorkflow.isBusy }
    private(set) var statusMessage = AppText.text("剪贴板历史保存在本机")
    // didSet 类似显式 setter 中的持久化副作用；与 Vue watch 不同，它紧跟属性赋值执行。
    var translationTarget: String {
        didSet {
            guard translationTarget != oldValue else { return }
            translationPreferences.setTextTargetLanguage(translationTarget)
            textTranslationPresenter.updateTargetLanguage(translationTarget)
        }
    }
    var screenshotTranslationSource: String {
        didSet {
            translationPreferences.setScreenshotSourceLanguage(screenshotTranslationSource)
        }
    }
    var screenshotTranslationTarget: String {
        didSet {
            translationPreferences.setScreenshotTargetLanguage(screenshotTranslationTarget)
        }
    }

    private var screenshotTranslationLanguages: TranslationLanguagePair {
        TranslationLanguagePair(
            sourceLanguage: screenshotTranslationSource,
            targetLanguage: screenshotTranslationTarget
        )
    }

    init(
        captureWorkflow: CaptureWorkflowCoordinator,
        clipboardController: ClipboardController,
        clipboardPresenter: ClipboardWindowPresenter,
        textTranslationPresenter: TextTranslationWindowPresenter,
        hotKeys: any GlobalHotKeyRegistering,
        translationPreferences: any TranslationPreferencesStoring
    ) {
        self.translationPreferences = translationPreferences
        self.captureWorkflow = captureWorkflow
        self.clipboardController = clipboardController
        self.clipboardPresenter = clipboardPresenter
        self.textTranslationPresenter = textTranslationPresenter
        self.hotKeys = hotKeys
        let preferences = translationPreferences.load()
        translationTarget = preferences.textTargetLanguage
        let screenshotLanguages = preferences.screenshotLanguages
        screenshotTranslationSource = screenshotLanguages.sourceLanguage
        screenshotTranslationTarget = screenshotLanguages.targetLanguage
        shortcutDescriptors = AppShortcutStore.load()
        captureWorkflow.onStatus = { [weak self] status in self?.statusMessage = status }
        captureWorkflow.onFailure = { [weak self] error in
            guard let self else { return }
            statusMessage = isPermissionFailure(error) ? AppText.text("需要系统授权") : error.localizedDescription
            if isPermissionFailure(error) { presentPermissionList(for: .screenCapture) }
            else { presentError(error) }
        }
        clipboardPresenter.onPasteFailed = { [weak self] error in
            self?.presentError(error)
        }
    }

    func registerGlobalHotKeys() {
        // 每个快捷键独立注册；其中一个冲突不能阻止其余功能继续可用。
        for action in AppShortcutAction.allCases {
            registerHotKey(
                action: action,
                descriptor: shortcutDescriptor(for: action)
            )
        }
    }

    func shortcutDescriptor(for action: AppShortcutAction) -> HotKeyDescriptor {
        shortcutDescriptors[action] ?? action.defaultDescriptor
    }

    func shortcutText(for action: AppShortcutAction) -> String {
        HotKeyDisplay.string(for: shortcutDescriptor(for: action))
    }

    @discardableResult
    func setShortcut(
        _ descriptor: HotKeyDescriptor,
        for action: AppShortcutAction
    ) -> Bool {
        if let conflict = shortcutDescriptors.first(where: {
            $0.key != action && $0.value == descriptor
        })?.key {
            shortcutConfigurationMessage = AppText.format("与“%@”的快捷键冲突", conflict.title)
            return false
        }

        let previousDescriptor = shortcutDescriptor(for: action)
        hotKeys.unregister(id: action.hotKeyID)
        do {
            try hotKeys.register(
                id: action.hotKeyID,
                descriptor: descriptor,
                handler: { [weak self] in self?.performShortcutAction(action) }
            )
            shortcutDescriptors[action] = descriptor
            AppShortcutStore.save(shortcutDescriptors)
            shortcutConfigurationMessage = AppText.format(
                "“%@”已设为 %@",
                action.title,
                HotKeyDisplay.string(for: descriptor)
            )
            statusMessage = AppText.text("快捷键已更新")
            return true
        } catch {
            try? hotKeys.register(
                id: action.hotKeyID,
                descriptor: previousDescriptor,
                handler: { [weak self] in self?.performShortcutAction(action) }
            )
            shortcutConfigurationMessage = error.localizedDescription
            statusMessage = error.localizedDescription
            return false
        }
    }

    func refreshClipboardHistoryPolicy() {
        clipboardController.refreshPolicy()
    }

    func capture() {
        captureWorkflow.capture(languages: screenshotTranslationLanguages)
    }

    func showClipboard() {
        guard !isBusy else {
            statusMessage = AppText.text("请先完成当前操作")
            return
        }
        clipboardPresenter.toggle()
    }

    func showTextTranslation() {
        presentTextTranslation(togglesVisibility: false)
    }

    private func presentTextTranslation(togglesVisibility: Bool) {
        guard !isBusy else {
            statusMessage = AppText.text("请先完成当前操作")
            return
        }
        let onTargetLanguageChange: @MainActor (String) -> Void = { [weak self] language in
            self?.translationTarget = language
        }
        if togglesVisibility {
            textTranslationPresenter.toggle(
                targetLanguage: translationTarget,
                onTargetLanguageChange: onTargetLanguageChange
            )
        } else {
            textTranslationPresenter.show(
                targetLanguage: translationTarget,
                onTargetLanguageChange: onTargetLanguageChange
            )
        }
    }

    func clearClipboardHistory() {
        Task {
            do {
                try await clipboardController.clearHistory()
                statusMessage = AppText.text("剪贴板历史已清空")
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func registerHotKey(
        action: AppShortcutAction,
        descriptor: HotKeyDescriptor
    ) {
        do {
            try hotKeys.register(
                id: action.hotKeyID,
                descriptor: descriptor,
                handler: { [weak self] in self?.performShortcutAction(action) }
            )
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func performShortcutAction(_ action: AppShortcutAction) {
        switch action {
        case .capture:
            capture()
        case .clipboard:
            showClipboard()
        case .textTranslation:
            presentTextTranslation(togglesVisibility: true)
        }
    }

    private func isPermissionFailure(_ error: Error) -> Bool {
        guard let failure = error as? AppFailure else { return false }
        if case .permissionDenied = failure {
            return true
        }
        return false
    }

    private func presentPermissionList(for permission: AppPermission) {
        NotificationCenter.default.post(name: .iSnipsterShouldShowPermissionList, object: permission)
    }

    private func presentError(_ error: Error) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = AppText.text("iSnipster 无法完成操作")
        alert.informativeText = error.localizedDescription
        // level 决定窗口相对其他层级的前后位置；同层窗口的顺序还由 orderFront/子窗口关系决定。
        alert.window.level = .floating
        // 进入嵌套模态事件循环并等待结果；当前调用栈尚未返回，不能假定弹窗期间所有应用事件都停止。
        alert.runModal()
    }
}
