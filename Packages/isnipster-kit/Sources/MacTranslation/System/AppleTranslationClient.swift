import MacShared
import TextTranslationFeature
// 阅读路线
// 调用方 await translate → 发布 configuration → SwiftUI translationTask 调 consume → 恢复 continuation。
// 超时、取消和成功共享完成门闩；系统会话由宿主提供，不能仅构造客户端就期望开始翻译。
// 官方参考（系统翻译会话与批量顺序）：https://developer.apple.com/documentation/translation/translating-text-within-your-app

import Foundation
import Observation
import iSnipsterCore
// @preconcurrency 用于与尚未完整提供并发标注的框架交互，可能降低相关诊断；它不提供锁。
// 本项目把系统会话限制在宿主回调的消费路径中，不保存为长期属性。
@preconcurrency import Translation

// @retroactive 表示为外部类型补上外部协议，@unchecked 将线程安全证明交给作者。
// 此处用文本构造 Request，发送后不再修改请求数组；更新 SDK 时仍需重新确认其 Sendable 声明，
// 不能把这类扩展当成所有并发诊断的通用修复。
extension TranslationSession.Request: @retroactive @unchecked Sendable {}

/// TranslationSession 由截图画布或文本翻译视图上的 SwiftUI translationTask 提供。
///
/// 本项目使用 `.translationTask` 提供会话，让首次下载语言包的系统确认界面有可见宿主。
/// 这个客户端只发布配置和待处理文本；宿主回调 consume，关闭宿主时再协调任务取消。
@MainActor
@Observable
public final class AppleTranslationClient: TextTranslating, TranslationSessionControlling {
    public private(set) var configuration: TranslationSession.Configuration?

    /// 标识系统翻译会话当前使用的源语言与目标语言组合。
    private struct LanguagePair: Equatable {
        let source: String?
        let target: String
    }

    /// 等待 SwiftUI TranslationSession 消费的一次翻译请求。
    private struct PendingRequest {
        // id 用于超时兜底时判断 pending 是否仍是同一次请求，避免误伤后续请求。
        let id: UUID
        let texts: [String]
        // gate 保证 continuation 只 resume 一次：consume 成功/失败与超时兜底可能同时到达。
        let gate: TranslationGate
    }

    /// 翻译请求的一次性完成门闩；内部锁保护“取出并清空 continuation”这一整体操作。
    /// consume 路径与超时路径可能竞争，靠它避免 CheckedContinuation 二次 resume 崩溃。
    private final class TranslationGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[String], Error>?

        init(_ continuation: CheckedContinuation<[String], Error>) {
            self.continuation = continuation
        }

        func resume(returning value: [String]) {
            take()?.resume(returning: value)
        }

        func resume(throwing error: Error) {
            take()?.resume(throwing: error)
        }

        // 锁内先把唯一 continuation 取走并置 nil；resume 在锁外执行，避免恢复任务时仍占锁。
        private func take() -> CheckedContinuation<[String], Error>? {
            lock.lock()
            defer { lock.unlock() }
            let pending = continuation
            continuation = nil
            return pending
        }
    }

    private var activePair: LanguagePair?
    private var pending: PendingRequest?
    private var timeoutTask: Task<Void, Never>?

    public init() {}

    public func validateLanguages(source: String?, target: String) async throws {
        guard let source else { return }
        let status = await LanguageAvailability().status(
            from: Locale.Language(identifier: source), to: Locale.Language(identifier: target))
        try Task.checkCancellation()
        guard status != .unsupported else {
            throw AppFailure.invalidData(AppText.text("系统暂不支持这组翻译语言，请重新选择"))
        }
    }

    public func translate(
        texts: [String],
        sourceLanguage: String?,
        targetLanguage: String
    ) async throws -> [String] {
        guard pending == nil else {
            throw AppFailure.unavailable(AppText.text(.translationBusy))
        }
        guard !texts.isEmpty else { return [] }
        try Task.checkCancellation()
        let requestID = UUID()

        // CheckedContinuation 把 SwiftUI translationTask 回调桥接成普通 async 方法；
        // cancellationHandler 则保证截图窗口关闭时不会留下一个永久 pending 的翻译请求。
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let gate = TranslationGate(continuation)
                pending = PendingRequest(id: requestID, texts: texts, gate: gate)
                let pair = LanguagePair(source: sourceLanguage, target: targetLanguage)

                if activePair == pair, configuration != nil {
                    // 同一 Configuration 调用 invalidate 会要求 translationTask 重新执行。
                    configuration?.invalidate()
                } else {
                    activePair = pair
                    configuration = TranslationSession.Configuration(
                        source: sourceLanguage.map { Locale.Language(identifier: $0) },
                        target: Locale.Language(identifier: targetLanguage)
                    )
                }

                scheduleTimeout(gate, requestID: requestID)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.cancelPendingRequest(id: requestID)
            }
        }
    }

    /// 最多等待 5 分钟；超时释放本次 pending 并报告失败，让后续翻译可以重试。
    /// 等待时间包含可能的语言包准备；请求 ID 防止旧计时任务结束后误伤新请求。
    private func scheduleTimeout(_ gate: TranslationGate, requestID: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) }
            catch { return }
            guard let self, self.pending?.id == requestID else { return }
            self.pending = nil
            self.timeoutTask = nil
            let failure = OperationFailure(category: .timeout, stage: "translation.apple",
                message: AppText.text(.translationTimeout))
            AppDiagnostics.failure(failure, stage: "translation.apple", requestID: requestID)
            gate.resume(throwing: failure)
        }
    }

    /// Controller 关闭编辑会话时会取消外层 Task；这里对称释放 continuation 和 pending。
    /// 截图超时时同步释放当前请求，避免恢复按钮后立即重试仍遇到 translationBusy。
    public func cancelPendingTranslation() {
        guard let request = pending else { return }
        cancelPendingRequest(id: request.id)
    }

    private func cancelPendingRequest(id requestID: UUID) {
        guard let request = pending, request.id == requestID else { return }
        pending = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        request.gate.resume(throwing: CancellationError())
        // 使当前 translationTask 失效，系统会尽力取消仍在进行的翻译工作。
        configuration?.invalidate()
    }

    /// 由宿主视图的 translationTask 回调。internal 可见性只允许 MacTranslation 模块调用，
    /// App 层和其他 Feature 无法绕过 TextTranslating 端口直接操作系统会话。
    func consume(using session: TranslationSession) async {
        guard !Task.isCancelled, let request = pending else { return }

        do {
            // sourceLanguage 为 nil 时调用 prepareTranslation() 会因为没有样本文本而失败。
            // translations(from:) 会使用实际 OCR 文本判断源语言，并以一个批次完成翻译；
            // 返回顺序与 Request 顺序一致，正好保持 OCR 文本和图片区域的下标对应关系。
            let requests = request.texts.map {
                TranslationSession.Request(sourceText: $0)
            }
            let responses = try await session.translations(from: requests)

            // 请求可能在 await 期间被编辑器取消；旧任务绝不能清空后来新建的 pending。
            guard pending?.id == request.id else { return }
            pending = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            request.gate.resume(returning: responses.map(\.targetText))
        } catch {
            guard pending?.id == request.id else { return }
            pending = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            if Task.isCancelled || TaskCancellation.isCancellation(error) {
                request.gate.resume(throwing: CancellationError())
            } else if TranslationError.unableToIdentifyLanguage ~= error {
                request.gate.resume(throwing: TextTranslationFailure.unableToIdentifyLanguage)
            } else {
                request.gate.resume(
                    throwing: OperationFailure(
                        category: .systemService, stage: "translation.apple",
                        message: AppText.format(.translationSystemFailed, error.localizedDescription),
                        underlying: error
                    )
                )
            }
        }
    }

}
