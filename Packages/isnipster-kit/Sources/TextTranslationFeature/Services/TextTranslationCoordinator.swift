import Foundation
import Observation
import iSnipsterCore

/// 多来源请求的唯一任务所有者；输出状态与完成快照，不保存界面控件或朗读对象。
@MainActor
@Observable
public final class TextTranslationCoordinator {
    public private(set) var results: [TextTranslationProvider: TextTranslationResultState] = [:]
    @ObservationIgnored public var onCompletion: (@MainActor (TextTranslationRequest, [TextTranslationProvider: TextTranslationResultState]) -> Void)?
    private let service: any TextTranslationServicing
    private var tasks: [TextTranslationProvider: Task<Void, Never>] = [:]
    private var taskIDs: [TextTranslationProvider: UUID] = [:]
    private var requestID: UUID?
    private var request: TextTranslationRequest?
    public var isTranslating: Bool { !tasks.isEmpty }

    public init(service: any TextTranslationServicing) { self.service = service }

    public func start(_ request: TextTranslationRequest, providers: [TextTranslationProvider]) {
        cancel()
        let providers = Array(Set(providers))
        guard !providers.isEmpty else { results = [:]; return }
        let id = UUID()
        requestID = id
        self.request = request
        results = Dictionary(uniqueKeysWithValues: providers.map { ($0, .loading) })
        for provider in providers {
            let taskID = UUID()
            taskIDs[provider] = taskID
            tasks[provider] = Task { [weak self] in
                guard let self else { return }
                let result: TextTranslationResultState
                do {
                    try Task.checkCancellation()
                    let output = try await service.translate(provider: provider, request: request)
                    try Task.checkCancellation()
                    result = .success(output)
                } catch {
                    if Task.isCancelled || TaskCancellation.isCancellation(error) {
                        result = .idle
                    } else {
                        AppDiagnostics.failure(error, stage: "translation.provider.\(provider.rawValue)", requestID: id)
                        result = .failure(error.localizedDescription)
                    }
                }
                guard requestID == id, taskIDs[provider] == taskID else { return }
                tasks[provider] = nil
                taskIDs[provider] = nil
                results[provider] = result
                completeIfReady()
            }
        }
    }

    public func removeProvider(_ provider: TextTranslationProvider) {
        taskIDs[provider] = nil
        tasks.removeValue(forKey: provider)?.cancel()
        service.cancel(provider: provider)
        results[provider] = nil
        completeIfReady()
    }

    public func cancel() {
        // 先使会话失效，再通知客户端；同步释放系统 pending 后才可开始下一次请求。
        requestID = nil
        request = nil
        let active = tasks
        tasks = [:]
        taskIDs = [:]
        for (provider, task) in active {
            task.cancel()
            service.cancel(provider: provider)
        }
        for provider in results.keys where results[provider]?.isLoading == true {
            results[provider] = .idle
        }
    }

    public func replaceResults(_ results: [TextTranslationProvider: TextTranslationResultState]) {
        cancel()
        self.results = results
    }

    private func completeIfReady() {
        guard requestID != nil, tasks.isEmpty, let request else { return }
        requestID = nil
        self.request = nil
        onCompletion?(request, results)
    }
}
