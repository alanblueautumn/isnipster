import CaptureFeature
import Foundation
import MacPlatform
import Observation
import iSnipsterCore

/// 一次截图从冻结屏幕到结束编辑的唯一流程所有者。
@MainActor
@Observable
final class CaptureWorkflowCoordinator {
    private enum State: Equatable {
        case idle
        case capturing(UUID)
        case selecting(UUID)
        case editing(UUID)

        var id: UUID? {
            switch self {
            case .idle: nil
            case let .capturing(id), let .selecting(id), let .editing(id): id
            }
        }
    }

    private let captureUseCase: CaptureUseCase
    private let editorPresenter: ImageEditorPresenter
    private let hotKeys: any GlobalHotKeyRegistering
    private let onBeginInteraction: @MainActor () -> Void
    private let onEndInteraction: @MainActor () -> Void
    private var state: State = .idle
    private var task: Task<Void, Never>?
    private var isEscapeRegistered = false
    private let escapeHotKeyID: UInt32 = 2
    var onStatus: (@MainActor (String) -> Void)?
    var onFailure: (@MainActor (Error) -> Void)?
    var isBusy: Bool { state != .idle }

    init(captureUseCase: CaptureUseCase, editorPresenter: ImageEditorPresenter,
         hotKeys: any GlobalHotKeyRegistering,
         onBeginInteraction: @escaping @MainActor () -> Void,
         onEndInteraction: @escaping @MainActor () -> Void) {
        self.captureUseCase = captureUseCase
        self.editorPresenter = editorPresenter
        self.hotKeys = hotKeys
        self.onBeginInteraction = onBeginInteraction
        self.onEndInteraction = onEndInteraction
        editorPresenter.onSessionEnd = { [weak self] in
            guard let self, case .editing = state else { return }
            finish()
        }
    }

    func capture(languages: TranslationLanguagePair) {
        if isBusy { cancel(); return }
        let id = UUID()
        state = .capturing(id)
        onStatus?(AppText.text("正在截图…"))
        registerEscape()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let capture = try await captureUseCase.captureArea { [weak self] in
                    guard let self, state.id == id else { return }
                    state = .selecting(id)
                    onBeginInteraction()
                }
                try Task.checkCancellation()
                guard state.id == id else { return }
                editorPresenter.present(image: capture.image, selection: capture.selection,
                    frozenFrame: capture.frozenFrame, translationLanguages: languages)
                state = .editing(id)
                task = nil
                captureUseCase.finishPresentation()
                onStatus?(AppText.text("完成"))
            } catch {
                guard state.id == id else { return }
                let cancelled = Task.isCancelled || TaskCancellation.isCancellation(error)
                finish()
                if cancelled {
                    onStatus?(AppText.text("已取消"))
                } else {
                    AppDiagnostics.failure(error, stage: "application.capture", requestID: id)
                    onFailure?(error)
                }
            }
        }
    }

    func cancel() {
        guard isBusy else { return }
        task?.cancel()
        finish()
        captureUseCase.cancelCapture()
        editorPresenter.dismissAll()
        onStatus?(AppText.text("已取消"))
    }

    private func finish() {
        guard isBusy else { return }
        state = .idle
        task = nil
        if isEscapeRegistered {
            hotKeys.unregister(id: escapeHotKeyID)
            isEscapeRegistered = false
        }
        onEndInteraction()
    }

    private func registerEscape() {
        do {
            try hotKeys.register(id: escapeHotKeyID,
                descriptor: HotKeyDescriptor(keyCode: 53, modifiers: []),
                handler: { [weak self] in self?.cancel() })
            isEscapeRegistered = true
        } catch {
            // 选区本地监听和再次按截图快捷键仍可取消。
        }
    }
}
