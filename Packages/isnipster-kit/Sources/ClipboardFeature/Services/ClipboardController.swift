// 阅读路线
// 读取顺序：start 建立监控 → pollPasteboard 采集 → pendingMutations 排队 → store 提交 → entries 刷新界面。
// 轮询、任务取消、FIFO 写队列各解决一个问题；MainActor 保证 UI 隔离，不会自动把同步 I/O 移到后台。
// 官方参考（Timer 与运行循环）：https://developer.apple.com/documentation/foundation/timer

import Foundation
import iSnipsterCore
import Observation

/// 主线程剪贴板监控器。
///
/// macOS 没有提供可靠的全局剪贴板变化通知，因此这里只轮询 changeCount；
/// 计数不变时不会读取实际内容，避免无意义地触发大对象解码。
///
/// Java 对照：这是 ViewModel + Scheduler。Timer 和 NSPasteboard 固定在 MainActor，
/// 历史集合的去重/裁剪交给注入的存储 actor 串行执行。
@MainActor
@Observable
public final class ClipboardController: NSObject {
    private enum HistoryMutation {
        case insert(ClipboardSnapshot)
        case remove(UUID)
        case markUsed(UUID)
        case toggleFavorite(UUID)
        case clearFavorites
        case category(ClipboardCategoryMutation, CheckedContinuation<Void, Error>)
        case applyPolicy
        case clear(CheckedContinuation<Void, Error>)

        var continuation: CheckedContinuation<Void, Error>? {
            switch self {
            case let .clear(value), let .category(_, value): value
            default: nil
            }
        }
    }

    public private(set) var history = ClipboardHistorySnapshot()
    public var entries: [ClipboardEntry] { history.entries }
    public var categories: [ClipboardCategory] { history.categories }
    public var query = ""
    public private(set) var isMonitoring = false
    public private(set) var persistenceErrorMessage: String?

    private let client: any PasteboardClient
    private let store: any ClipboardHistoryStoring
    private let maximumSingleItemBytes: Int
    private let policyProvider: @MainActor () -> ClipboardHistoryPolicy
    private var timer: Timer?
    private var snapshotTask: Task<Void, Never>?
    private var observedChangeCount = 0
    // actor 只保证隔离访问，不能替调用者决定业务提交顺序；这里用显式 FIFO 队列串行提交历史操作。
    private var pendingMutations: [HistoryMutation] = []
    private var persistenceTask: Task<Void, Never>?
    private var historyLoadTask: Task<Void, Never>?
    private var persistenceGeneration = UUID()
    private var nextMaintenanceDate = Date.distantPast
    private var isHistoryLoaded = false

    public init(
        client: any PasteboardClient,
        store: any ClipboardHistoryStoring,
        policyProvider: @escaping @MainActor () -> ClipboardHistoryPolicy,
        maximumSingleItemBytes: Int = 20 * 1_024 * 1_024
    ) {
        self.client = client
        self.store = store
        self.policyProvider = policyProvider
        self.maximumSingleItemBytes = maximumSingleItemBytes
        super.init()
    }

    public var filteredEntries: [ClipboardEntry] {
        // 计算属性不存储第二份数组；搜索词变化时 SwiftUI 重新读取并计算。
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.content.searchText.localizedCaseInsensitiveContains(query)
                || ($0.sourceApplicationName?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    public func start() {
        guard timer == nil else { return }
        observedChangeCount = client.changeCount
        isMonitoring = true
        isHistoryLoaded = false
        nextMaintenanceDate = .now.addingTimeInterval(60)

        // 磁盘读取延迟到 actor 上执行，避免应用启动时在主线程同步解码历史。
        historyLoadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let restoredEntries = try await self.store.allEntries(
                    policy: self.policyProvider()
                )
                try Task.checkCancellation()
                self.history = restoredEntries
                let warning = await self.store.maintenanceWarning()
                try Task.checkCancellation()
                self.persistenceErrorMessage = warning
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                AppDiagnostics.failure(error, stage: "clipboard.history.load")
                self.persistenceErrorMessage = "无法读取剪贴板历史：\(error.localizedDescription)"
            }
            self.isHistoryLoaded = true
            self.historyLoadTask = nil
            self.drainPendingMutationsIfNeeded()
        }

        // 用 selector 形式的 Timer，确保回调始终落在主 RunLoop，不把 AppKit 对象
        // 捕获进 Sendable closure。
        let timer = Timer(
            timeInterval: 0.5,
            target: self,
            selector: #selector(pollPasteboard),
            userInfo: nil,
            repeats: true
        )
        // RunLoop 是主线程事件循环；common 模式让轮询在常见交互模式下也能被调度，Timer 并非精确定时器。
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        historyLoadTask?.cancel()
        historyLoadTask = nil
        persistenceTask?.cancel()
        persistenceTask = nil
        persistenceGeneration = UUID()
        for mutation in pendingMutations {
            if let continuation = mutation.continuation {
                continuation.resume(throwing: CancellationError())
            }
        }
        pendingMutations.removeAll(keepingCapacity: false)
        isMonitoring = false
    }

    public func activate(_ entry: ClipboardEntry, asPlainText: Bool = false) async throws {
        try Task.checkCancellation()
        // Feature 只负责将内容写回系统剪贴板；是否继续向原应用发送粘贴按键由平台层决定。
        if asPlainText, let plainText = entry.content.plainTextValue {
            try client.write(.text(plainText))
        } else if case .imagePNG = entry.content {
            try await client.writeImage(entry.content)
        } else {
            try client.write(entry.content)
        }
        // 自己写回剪贴板后立即同步计数，避免下一轮把同一条再次采集。
        observedChangeCount = client.changeCount
        markUsed(entry)
    }

    /// 平台层使用文件承诺等原生对象直接改写 NSPasteboard 后，同步变化计数，
    /// 避免轮询器把刚激活的历史记录重新采集一遍。
    public func synchronizePasteboardChangeCount() {
        observedChangeCount = client.changeCount
    }

    /// 只写入系统剪贴板，不进入应用历史。翻译结果等隐私敏感的应用内输出走此入口。
    public func writeWithoutRecording(_ content: ClipboardContent) throws {
        try client.write(content)
        observedChangeCount = client.changeCount
    }

    /// 应用自身生成的内容同时写入系统剪贴板与历史。主动同步 changeCount 可以避免
    /// 轮询器在下一轮把同一份内容重复采集，历史则直接入队，不依赖 0.5 秒轮询窗口。
    public func writeAndRecord(_ content: ClipboardContent) throws {
        try client.write(content)
        recordApplicationGenerated(content)
    }

    /// 图片在平台 actor 编码完成后写回剪贴板，再将历史插入排队；两者不是同一原子事务。
    public func writeImageAndRecord(_ content: ClipboardContent) async throws {
        try await client.writeImage(content)
        recordApplicationGenerated(content)
    }

    /// 文件 URL 写入等平台操作会绕过 PasteboardClient；调用方提供可持久化的等价内容，
    /// Controller 同样同步系统计数并直接加入历史。
    public func recordApplicationGenerated(_ content: ClipboardContent) {
        observedChangeCount = client.changeCount
        let bundle = Bundle.main
        let sourceName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "iSnipster"
        let snapshot = ClipboardSnapshot(
            content: content,
            sourceApplicationName: sourceName,
            sourceBundleIdentifier: bundle.bundleIdentifier
        )
        guard shouldRecord(snapshot, policy: policyProvider()) else { return }
        pendingMutations.append(.insert(snapshot))
        drainPendingMutationsIfNeeded()
    }

    /// 设置变更后立即应用保留时长和数量限制；关闭记录只停止后续采集，不删除已有历史。
    public func refreshPolicy() {
        snapshotTask?.cancel()
        snapshotTask = nil
        scheduleMaintenance()
    }

    /// 所有历史写入共享队列；维护不会取消正在提交的写入，也不会用旧快照覆盖新列表。
    public func scheduleMaintenance() {
        nextMaintenanceDate = .now.addingTimeInterval(60)
        guard !pendingMutations.contains(where: {
            if case .applyPolicy = $0 { return true }
            return false
        }) else { return }
        pendingMutations.append(.applyPolicy)
        drainPendingMutationsIfNeeded()
    }

    public func clear() {
        Task {
            do {
                try await clearHistory()
            } catch {
                // 错误已写入 persistenceErrorMessage；清理失败时显示实际提交后的列表。
            }
        }
    }

    public func clearHistory() async throws {
        snapshotTask?.cancel()
        snapshotTask = nil
        if !isHistoryLoaded, historyLoadTask == nil { isHistoryLoaded = true }
        // 清空之前尚未提交的动作不再落盘；已经开始的写入先结束，再按队列顺序清空。
        pendingMutations.removeAll {
            if case .clear = $0 { return false }
            $0.continuation?.resume(throwing: CancellationError())
            return true
        }
        try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(.clear(continuation))
            drainPendingMutationsIfNeeded()
        }
    }

    public func remove(_ entry: ClipboardEntry) {
        pendingMutations.append(.remove(entry.id))
        drainPendingMutationsIfNeeded()
    }

    /// 用户从历史中再次复制、粘贴或拖出内容后，累加次数并移到最近使用位置。
    /// 保留稳定 id，避免影响分类绑定和 SwiftUI 卡片身份。
    public func markUsed(_ entry: ClipboardEntry) {
        pendingMutations.append(.markUsed(entry.id))
        drainPendingMutationsIfNeeded()
    }

    public func toggleFavorite(_ entry: ClipboardEntry) {
        pendingMutations.append(.toggleFavorite(entry.id))
        drainPendingMutationsIfNeeded()
    }

    public func clearFavorites() {
        pendingMutations.append(.clearFavorites)
        drainPendingMutationsIfNeeded()
    }

    public func updateCategory(_ mutation: ClipboardCategoryMutation) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pendingMutations.append(.category(mutation, continuation))
            drainPendingMutationsIfNeeded()
        }
    }

    @objc
    private func pollPasteboard() {
        // 独立于内容变化和采集开关；睡眠期间经过的时间在下一次 tick 补处理。
        if Date.now >= nextMaintenanceDate { scheduleMaintenance() }
        // @objc 让 Objective-C 运行时可通过 selector 找到该 Swift 方法。
        // 同一时间只读取一条，像 Vue 中给异步 action 加 in-flight 标记。
        // 大图处理期间不启动第二次读取；下一次 tick 会采集系统剪贴板的最新版本。
        guard snapshotTask == nil else { return }
        let latest = client.changeCount
        guard latest != observedChangeCount else { return }
        observedChangeCount = latest
        let policy = policyProvider()
        guard policy.recordsHistory else { return }
        snapshotTask = Task { [weak self] in
            guard let self else { return }
            // stop 后的旧任务不能清除新一轮 start 创建的任务引用。
            defer { if !Task.isCancelled { self.snapshotTask = nil } }
            guard !Task.isCancelled, self.client.changeCount == latest,
                  let snapshot = await self.client.readSnapshot(maxBytes: self.maximumSingleItemBytes),
                  !Task.isCancelled else { return }
            guard self.shouldRecord(snapshot, policy: self.policyProvider()) else { return }
            self.pendingMutations.append(.insert(snapshot))
            self.drainPendingMutationsIfNeeded()
        }
    }

    private func drainPendingMutationsIfNeeded() {
        guard isHistoryLoaded, persistenceTask == nil else { return }
        let generation = persistenceGeneration
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            while !self.pendingMutations.isEmpty {
                guard !Task.isCancelled else { break }
                let mutation = self.pendingMutations.removeFirst()
                do {
                    let updatedEntries: ClipboardHistorySnapshot
                    switch mutation {
                    case let .insert(snapshot):
                        let policy = self.policyProvider()
                        guard self.shouldRecord(snapshot, policy: policy) else { continue }
                        updatedEntries = try await self.store.insert(snapshot, policy: policy)
                    case let .remove(id):
                        updatedEntries = try await self.store.remove(
                            id: id,
                            policy: self.policyProvider()
                        )
                    case .applyPolicy:
                        updatedEntries = try await self.store.apply(policy: self.policyProvider())
                    case .clear:
                        updatedEntries = try await self.store.clear()
                    case let .markUsed(id):
                        updatedEntries = try await self.store.markUsed(
                            id: id,
                            policy: self.policyProvider()
                        )
                    case let .toggleFavorite(id):
                        updatedEntries = try await self.store.toggleFavorite(
                            id: id,
                            policy: self.policyProvider()
                        )
                    case let .category(change, _):
                        updatedEntries = try await self.store.updateCategory(change, policy: self.policyProvider())
                    case .clearFavorites:
                        updatedEntries = try await self.store.clearFavorites(policy: self.policyProvider())
                    }
                    try Task.checkCancellation()
                    self.history = updatedEntries
                    let warning = await self.store.maintenanceWarning()
                    try Task.checkCancellation()
                    self.persistenceErrorMessage = warning
                    if let continuation = mutation.continuation {
                        if case .clear = mutation, let warning {
                            continuation.resume(throwing: ClipboardMaintenanceError(message: warning))
                        } else {
                            continuation.resume()
                        }
                    }
                } catch is CancellationError {
                    if let continuation = mutation.continuation {
                        continuation.resume(throwing: CancellationError())
                    }
                    break
                } catch {
                    if Task.isCancelled {
                        if let continuation = mutation.continuation {
                            continuation.resume(throwing: CancellationError())
                        }
                        break
                    }
                    AppDiagnostics.failure(error, stage: "clipboard.history.commit")
                    let action: String
                    switch mutation {
                    case .insert:
                        action = "保存"
                    case .remove:
                        action = "删除"
                    case .markUsed, .toggleFavorite, .clearFavorites, .category:
                        action = "更新"
                    case .applyPolicy:
                        action = "整理"
                    case .clear:
                        action = "清空"
                    }
                    self.persistenceErrorMessage = "无法\(action)剪贴板历史：\(error.localizedDescription)"
                    if let continuation = mutation.continuation { continuation.resume(throwing: error) }
                }
            }
            guard self.persistenceGeneration == generation else { return }
            self.persistenceTask = nil
            if !self.pendingMutations.isEmpty {
                self.drainPendingMutationsIfNeeded()
            }
        }
    }

    // 这里按设置和来源名称做启发式过滤；来源取自采集时前台应用，不能据此保证识别所有敏感复制。
    private func shouldRecord(
        _ snapshot: ClipboardSnapshot,
        policy: ClipboardHistoryPolicy
    ) -> Bool {
        guard policy.recordsHistory else { return false }
        let contentAllowed = switch snapshot.content {
        case .text, .url: policy.recordsText
        case .imagePNG: policy.recordsImages
        case .files: policy.recordsFiles
        case .color: policy.recordsColors
        }
        guard contentAllowed else { return false }

        let source = [snapshot.sourceBundleIdentifier, snapshot.sourceApplicationName]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let passwordManagerMarkers = [
            "1password", "agilebits", "bitwarden", "lastpass", "dashlane",
            "keeper", "enpass", "keepass", "proton pass", "password safe"
        ]
        return !passwordManagerMarkers.contains(where: source.contains)
    }
}

private struct ClipboardMaintenanceError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
