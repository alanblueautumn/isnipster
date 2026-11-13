import MacShared
import MacScreenshotSupport
import TextTranslationFeature
import Foundation
import ImageTranslationFeature
import RecognitionFeature
import iSnipsterCore

/// 编辑任务唯一所有者；窗口只发出请求并在关闭时取消。
@MainActor
final class EditorOperationCoordinator {
    private let translationTimeout: @MainActor () -> Int
    private let exportService: EditorExportService
    private let session: InlineEditorSession
    private let translationSession: any TranslationSessionControlling
    private let recognize: @MainActor () async throws -> [OCRTextRegion]
    private let translate: @MainActor (String?, String) async throws -> ImageTranslationResult
    private let redact: @MainActor () async throws -> Int
    private var task: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var requestID: UUID? { session.operationState.requestID }
    private var isClosed: Bool { session.operationState == .closed }
    var onOCRChange: (@MainActor () -> Void)?

    init(session: InlineEditorSession, translationSession: any TranslationSessionControlling,
         translationTimeout: @escaping @MainActor () -> Int,
         exportService: EditorExportService,
         recognize: @escaping @MainActor () async throws -> [OCRTextRegion],
         translate: @escaping @MainActor (String?, String) async throws -> ImageTranslationResult,
         redact: @escaping @MainActor () async throws -> Int) {
        self.translationTimeout = translationTimeout
        self.exportService = exportService
        self.session = session
        self.translationSession = translationSession
        self.recognize = recognize
        self.translate = translate
        self.redact = redact
    }

    func performOCR() {
        guard requestID == nil, !isClosed else { return }
        session.clearOCRRegions()
        onOCRChange?()
        run({ .processing($0, .ocr) }, operation: recognize) { [weak self] regions in
            self?.session.replaceOCRRegions(with: regions)
            self?.onOCRChange?()
        }
    }

    func performSmartRedaction() {
        run({ .processing($0, .redaction) }, operation: redact) { _ in }
    }

    func performTranslation() {
        let source = session.translationSourceLanguage == "auto" ? nil : session.translationSourceLanguage
        let target = session.translationTargetLanguage
        let seconds = translationTimeout()
        run({ .processing($0, .translation) }, timeout: seconds, operation: { [translate, translationSession] in
            try await translationSession.validateLanguages(source: source, target: target)
            try Task.checkCancellation()
            return try await translate(source, target)
        }) { [weak self] result in
            guard let self else { return }
            session.document.replaceOriginal(with: result.image)
            if let fallback = result.appliedFallback {
                session.translationSourceLanguage = Locale.Language(identifier: fallback.sourceLanguage).minimalIdentifier
                session.translationTargetLanguage = Locale.Language(identifier: fallback.targetLanguage).minimalIdentifier
            }
        }
    }

    func performExport(_ target: EditorExportTarget, completion: @escaping @MainActor (EditorExportResult) -> Void) {
        guard session.operationState == .idle else { return }
        session.commitTextEntry()
        session.cancelDraft()
        let snapshot = session.document.snapshot()
        run({ .exporting($0, target) }, operation: { [exportService] in
            try await exportService.export(snapshot, to: target)
        }, apply: completion)
    }

    func cancel() {
        let wasTranslation: Bool
        if case .processing(_, .translation) = session.operationState { wasTranslation = true }
        else { wasTranslation = false }
        session.operationState = .closed
        task?.cancel()
        timeoutTask?.cancel()
        task = nil
        timeoutTask = nil
        if wasTranslation { translationSession.cancelPendingTranslation() }
        onOCRChange = nil
    }

    private func run<Result: Sendable>(
        _ makeState: (UUID) -> EditorOperationState, timeout: Int? = nil,
        operation: @escaping @MainActor () async throws -> Result,
        apply: @escaping @MainActor (Result) -> Void
    ) {
        guard requestID == nil, !isClosed else { return }
        let id = UUID()
        session.operationState = makeState(id)
        session.errorMessage = nil
        if let timeout {
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                guard let self, !isClosed, requestID == id else { return }
                task?.cancel()
                if case .processing(_, .translation) = session.operationState { translationSession.cancelPendingTranslation() }
                finish(id)
                let failure = OperationFailure(category: .timeout, stage: "capture.translation",
                                               message: AppText.text(.translationTimeout))
                AppDiagnostics.failure(failure, stage: "capture.translation", requestID: id)
                session.errorMessage = failure.localizedDescription
            }
        }
        task = Task { [weak self] in
            guard let self else { return }
            defer { finish(id) }
            do {
                try Task.checkCancellation()
                let result = try await operation()
                try Task.checkCancellation()
                guard !isClosed, requestID == id else { return }
                apply(result)
            } catch is CancellationError {
            } catch AppFailure.cancelled {
            } catch {
                guard !isClosed, requestID == id else { return }
                AppDiagnostics.failure(error, stage: "capture.editor", requestID: session.document.id)
                session.errorMessage = error.localizedDescription
            }
        }
    }

    private func finish(_ id: UUID) {
        guard requestID == id else { return }
        session.operationState = .idle
        timeoutTask?.cancel()
        timeoutTask = nil
        task = nil
    }
}
