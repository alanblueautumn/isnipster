import MacShared
import MacPreferences
// 阅读路线
// 历史存储 actor：加载索引 → 更新内存列表 → 提交索引 → 删除失效图片/释放文件访问。
// 失败时恢复之前的内存状态；这是手写提交协议，不是数据库事务，也不是每条 await 都有原子性。
// 官方参考（UserDefaults 小型偏好存储）：https://developer.apple.com/documentation/foundation/userdefaults

import CryptoKit
import ClipboardFeature
import Foundation
import iSnipsterCore

/// 剪贴板历史仓库。小型索引和图片原始数据分开保存，避免每次变化都重写整份图片历史。
public actor ClipboardHistoryStore: ClipboardHistoryStoring {
    private let byteBudget: Int
    private let storageDirectory: URL
    private let indexURL: URL
    private let imageDirectory: URL

    private var categories: [ClipboardCategory] = []
    private var historySnapshot: ClipboardHistorySnapshot {
        ClipboardHistorySnapshot(entries: entries, categories: categories)
    }
    private var entries: [ClipboardEntry] = []
    private var storedEntries: [StoredEntry] = []
    private var totalBytes = 0
    private var isLoaded = false
    private var activeSecurityScopedURLs: [UUID: [URL]] = [:]
    // 暂时无法解析的记录仍按原格式保存，下一次维护重试，不能因离线而丢失引用。
    private var unavailableEntries: [StoredEntry] = []
    private var cleanupWarning: String?

    /// 返回清理阶段的非致命警告；历史索引已成功更新与旧图片完全删除是两个结果。
    public func maintenanceWarning() async -> String? { cleanupWarning }

    deinit {
        for urls in activeSecurityScopedURLs.values {
            urls.forEach { $0.stopAccessingSecurityScopedResource() }
        }
    }

    /// `persistenceURL` 表示历史目录；默认位于应用支持目录内。
    public init(
        byteBudget: Int = 128 * 1_024 * 1_024,
        persistenceURL: URL? = nil
    ) {
        self.byteBudget = byteBudget
        let directory = persistenceURL ?? Self.defaultPersistenceDirectory()
        storageDirectory = directory
        indexURL = directory.appendingPathComponent("Index.plist", isDirectory: false)
        imageDirectory = directory.appendingPathComponent("Images", isDirectory: true)

    }

    /// 按需加载磁盘历史并返回当前可用列表；无法恢复的条目另存，供后续维护重试。
    public func allEntries(policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot {
        try Task.checkCancellation()
        try loadIfNeeded(policy: policy)
        return historySnapshot
    }

    @discardableResult
    /// 生成记录并应用去重与预算，先提交索引再回收旧图片；写入失败恢复先前内存状态。
    public func insert(
        _ snapshot: ClipboardSnapshot,
        policy: ClipboardHistoryPolicy
    ) async throws -> ClipboardHistorySnapshot {
        try Task.checkCancellation()
        try loadIfNeeded(policy: policy)

        let digest = SHA256.hash(data: snapshot.content.deduplicationData)
        let fingerprint = digest.map { String(format: "%02x", $0) }.joined()
        if policy.removesDuplicates,
           let duplicate = entries.first(where: { $0.fingerprint == fingerprint }) {
            // 重复复制沿用同一条记录，保留首次创建时间和累计使用次数。
            return try await markUsed(id: duplicate.id, policy: policy)
        }
        let entry = ClipboardEntry(
            fingerprint: fingerprint,
            content: snapshot.content,
            sourceApplicationName: snapshot.sourceApplicationName,
            sourceBundleIdentifier: snapshot.sourceBundleIdentifier
        )

        // 图片先独立落盘；索引写入成功后才删除被替换和被裁剪记录的旧图片。
        var storedEntry = try makeStoredEntry(from: entry)
        let residentEntry: ClipboardEntry
        do {
            // 图片转为映射数据，文件书签则在记录存活期间持有对应访问权。
            residentEntry = try materialize(&storedEntry)
        } catch {
            if let fileName = storedEntry.imageFileName { removeImages(named: [fileName]) }
            throw error
        }
        let previousEntries = entries
        let previousStoredEntries = storedEntries
        let previousUnavailableEntries = unavailableEntries
        let previousTotalBytes = totalBytes
        var obsoleteImages: [String] = []

        if policy.removesDuplicates {
            unavailableEntries.removeAll { $0.fingerprint == fingerprint }
        }
        entries.insert(residentEntry, at: 0)
        storedEntries.insert(storedEntry, at: 0)
        totalBytes += residentEntry.content.estimatedBytes
        obsoleteImages.append(contentsOf: trim(using: policy))

        do {
            try Task.checkCancellation()
            try writeIndex()
            releaseUnusedAccess()
            removeImages(named: obsoleteImages)
            return historySnapshot
        } catch {
            entries = previousEntries
            storedEntries = previousStoredEntries
            unavailableEntries = previousUnavailableEntries
            releaseUnusedAccess()
            totalBytes = previousTotalBytes
            if let fileName = storedEntry.imageFileName { removeImages(named: [fileName]) }
            throw error
        }
    }

    /// 用最新策略重新整理历史，并重试失效引用；未改变索引时避免重复写入。
    public func apply(policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot {
        try Task.checkCancellation()
        try loadIfNeeded(policy: policy)

        let previousEntries = entries
        let previousStoredEntries = storedEntries
        let previousUnavailableEntries = unavailableEntries
        let previousTotalBytes = totalBytes
        retryUnavailableEntries()
        refreshFileAccess()
        let obsoleteImages = trim(using: policy)

        do {
            if storedEntries != previousStoredEntries || unavailableEntries != previousUnavailableEntries {
                try writeIndex()
            }
            releaseUnusedAccess()
            removeImages(named: obsoleteImages)
            cleanupOrphanedImages()
            return historySnapshot
        } catch {
            entries = previousEntries
            storedEntries = previousStoredEntries
            unavailableEntries = previousUnavailableEntries
            releaseUnusedAccess()
            totalBytes = previousTotalBytes
            throw error
        }
    }

    /// 先保存旧状态，再提交空索引；成功后清理孤立资源，失败则恢复可见历史。
    public func clear() async throws -> ClipboardHistorySnapshot {
        try Task.checkCancellation()
        let previousEntries = entries
        let previousStoredEntries = storedEntries
        let previousUnavailableEntries = unavailableEntries
        let previousTotalBytes = totalBytes
        let previousIsLoaded = isLoaded

        entries.removeAll(keepingCapacity: false)
        storedEntries.removeAll(keepingCapacity: false)
        unavailableEntries.removeAll(keepingCapacity: false)
        totalBytes = 0
        isLoaded = true

        do {
            try writeIndex()
            releaseUnusedAccess()
            cleanupOrphanedImages()
            return historySnapshot
        } catch {
            entries = previousEntries
            storedEntries = previousStoredEntries
            unavailableEntries = previousUnavailableEntries
            releaseUnusedAccess()
            totalBytes = previousTotalBytes
            isLoaded = previousIsLoaded
            throw error
        }
    }

    /// 按稳定 UUID 删除一条记录；索引写成功后再删除图片，避免磁盘索引指向已删内容。
    public func remove(
        id: UUID,
        policy: ClipboardHistoryPolicy
    ) async throws -> ClipboardHistorySnapshot {
        try Task.checkCancellation()
        try loadIfNeeded(policy: policy)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return historySnapshot }

        let previousEntries = entries
        let previousStoredEntries = storedEntries
        let previousUnavailableEntries = unavailableEntries
        let previousTotalBytes = totalBytes
        let removed = entries.remove(at: index)
        let removedStorage = storedEntries.remove(at: index)
        totalBytes -= removed.content.estimatedBytes

        do {
            try writeIndex()
            releaseUnusedAccess()
            if let fileName = removedStorage.imageFileName {
                removeImages(named: [fileName])
            }
            return historySnapshot
        } catch {
            entries = previousEntries
            storedEntries = previousStoredEntries
            unavailableEntries = previousUnavailableEntries
            releaseUnusedAccess()
            totalBytes = previousTotalBytes
            throw error
        }
    }

    /// 累加使用次数并移到最前，保留 id 与创建时间；提交失败时回滚次数和顺序。
    public func markUsed(
        id: UUID,
        policy: ClipboardHistoryPolicy
    ) async throws -> ClipboardHistorySnapshot {
        try Task.checkCancellation()
        try loadIfNeeded(policy: policy)
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return historySnapshot
        }

        let previousEntries = entries
        let previousStoredEntries = storedEntries
        let previousUnavailableEntries = unavailableEntries
        var entry = entries.remove(at: index)
        var storedEntry = storedEntries.remove(at: index)
        entry.usageCount += 1
        storedEntry.usageCount = entry.usageCount
        entries.insert(entry, at: 0)
        storedEntries.insert(storedEntry, at: 0)

        do {
            try Task.checkCancellation()
            try writeIndex()
            releaseUnusedAccess()
            return historySnapshot
        } catch {
            entries = previousEntries
            storedEntries = previousStoredEntries
            unavailableEntries = previousUnavailableEntries
            releaseUnusedAccess()
            throw error
        }
    }

    /// 收藏只更新标记，不改变记录的创建时间、使用次数和位置。
    public func toggleFavorite(
        id: UUID,
        policy: ClipboardHistoryPolicy
    ) async throws -> ClipboardHistorySnapshot {
        try Task.checkCancellation()
        try loadIfNeeded(policy: policy)
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return historySnapshot }

        let previousEntry = entries[index]
        let previousStoredEntry = storedEntries[index]
        entries[index].isFavorite.toggle()
        storedEntries[index].isFavorite = entries[index].isFavorite

        do {
            try Task.checkCancellation()
            try writeIndex()
            return historySnapshot
        } catch {
            entries[index] = previousEntry
            storedEntries[index] = previousStoredEntry
            throw error
        }
    }

    /// 一次提交取消全部收藏，包括暂时无法访问的文件记录。
    public func clearFavorites(policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot {
        try Task.checkCancellation()
        try loadIfNeeded(policy: policy)
        guard entries.contains(where: { $0.isFavorite })
            || storedEntries.contains(where: { $0.isFavorite == true })
            || unavailableEntries.contains(where: { $0.isFavorite == true }) else { return historySnapshot }

        let previousEntries = entries
        let previousStoredEntries = storedEntries
        let previousUnavailableEntries = unavailableEntries
        for index in entries.indices where entries[index].isFavorite {
            entries[index].isFavorite = false
        }
        for index in storedEntries.indices where storedEntries[index].isFavorite == true {
            storedEntries[index].isFavorite = false
        }
        for index in unavailableEntries.indices where unavailableEntries[index].isFavorite == true {
            unavailableEntries[index].isFavorite = false
        }

        do {
            try Task.checkCancellation()
            try writeIndex()
            return historySnapshot
        } catch {
            entries = previousEntries
            storedEntries = previousStoredEntries
            unavailableEntries = previousUnavailableEntries
            throw error
        }
    }

    public func updateCategory(
        _ mutation: ClipboardCategoryMutation,
        policy: ClipboardHistoryPolicy
    ) async throws -> ClipboardHistorySnapshot {
        try Task.checkCancellation()
        try loadIfNeeded(policy: policy)
        let previousCategories = categories
        let previousEntries = entries
        let previousStoredEntries = storedEntries
        let previousUnavailableEntries = unavailableEntries
        switch mutation {
        case let .create(category):
            let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  !categories.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
                throw AppFailure.invalidData(AppText.text("分类名称不能为空或重复"))
            }
            categories.append(ClipboardCategory(id: category.id, name: name))
        case let .remove(id):
            categories.removeAll { $0.id == id }
            for index in entries.indices where entries[index].categoryID == id {
                entries[index].categoryID = nil
            }
            for index in storedEntries.indices where storedEntries[index].categoryID == id {
                storedEntries[index].categoryID = nil
            }
            for index in unavailableEntries.indices where unavailableEntries[index].categoryID == id {
                unavailableEntries[index].categoryID = nil
            }
        case let .assign(entryID, categoryID):
            guard categoryID == nil || categories.contains(where: { $0.id == categoryID }) else {
                throw AppFailure.invalidData(AppText.text("分类不存在"))
            }
            guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return historySnapshot }
            entries[index].categoryID = categoryID
            storedEntries[index].categoryID = categoryID
        }
        do {
            try Task.checkCancellation()
            try writeIndex()
            return historySnapshot
        } catch {
            categories = previousCategories
            entries = previousEntries
            storedEntries = previousStoredEntries
            unavailableEntries = previousUnavailableEntries
            throw error
        }
    }

    /// 延迟加载类似 lazy store 初始化；解码索引后逐项物化图片/文件，坏记录不会阻止其他项恢复。
    private func loadIfNeeded(policy: ClipboardHistoryPolicy) throws {
        guard !isLoaded else { return }
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            isLoaded = true
            return
        }
        let data = try Data(contentsOf: indexURL)
        // Property List 是 Apple 常见结构化配置格式；Decoder 按 Codable 类型还原，不是执行文件内的 Swift 代码。
        let decoded = try PropertyListDecoder().decode(StoredHistory.self, from: data)
        categories = decoded.categories

        var restoredEntries: [ClipboardEntry] = []
        var validStoredEntries: [StoredEntry] = []
        for var stored in decoded.entries {
            if let entry = try? materialize(&stored) {
                restoredEntries.append(entry)
                validStoredEntries.append(stored)
            } else {
                unavailableEntries.append(stored)
            }
        }

        entries = restoredEntries
        storedEntries = validStoredEntries
        totalBytes = entries.reduce(0) { $0 + $1.content.estimatedBytes }
        isLoaded = true
        // 只在提交成功后释放访问权/删除图片。索引失败时允许下次完整重试。
        let obsoleteImages = trim(using: policy)
        do {
            try writeIndex()
            releaseUnusedAccess()
            removeImages(named: obsoleteImages)
            cleanupOrphanedImages()
        } catch {
            entries = []
            storedEntries = []
            unavailableEntries = []
            totalBytes = 0
            isLoaded = false
            releaseUnusedAccess()
            throw error
        }
    }

    /// 返回需要在新索引成功写入后删除的图片文件。
    private func trim(using policy: ClipboardHistoryPolicy) -> [String] {
        var obsoleteImages: [String] = []
        if let retentionDays = policy.retentionDays,
           let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: .now) {
            for index in entries.indices.reversed()
            where entries[index].capturedAt < cutoff {
                totalBytes -= entries.remove(at: index).content.estimatedBytes
                if let fileName = storedEntries.remove(at: index).imageFileName {
                    obsoleteImages.append(fileName)
                }
            }
        }
        if let days = policy.retentionDays,
           let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) {
            unavailableEntries.removeAll { $0.capturedAt < cutoff }
        }
        while entries.count + unavailableEntries.count > policy.maximumItems {
            if let unavailable = unavailableEntries.last,
               entries.last.map({ $0.capturedAt > unavailable.capturedAt }) ?? true {
                unavailableEntries.removeLast()
            } else if let removed = entries.popLast(), let stored = storedEntries.popLast() {
                totalBytes -= removed.content.estimatedBytes
                if let fileName = stored.imageFileName { obsoleteImages.append(fileName) }
            } else { break }
        }
        while totalBytes > byteBudget {
            guard let removed = entries.popLast(), let stored = storedEntries.popLast() else { break }
            totalBytes -= removed.content.estimatedBytes
            if let fileName = stored.imageFileName {
                obsoleteImages.append(fileName)
            }
        }
        return obsoleteImages
    }

}

private extension ClipboardHistoryStore {
    /// 将内存模型转成磁盘模型：图片存文件名，外部文件存 bookmark，避免把大图塞入索引。
    func makeStoredEntry(from entry: ClipboardEntry) throws -> StoredEntry {
        let storedContent: StoredEntry.Content
        switch entry.content {
        case let .text(value):
            storedContent = .text(value)
        case let .url(url):
            storedContent = .url(url)
        case let .files(urls):
            let files = try urls.map { url in
                // 开始使用 security-scoped URL 的授权；返回 true 时需要配对 stopAccessing，不能只靠 URL 离开作用域释放。
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                return StoredEntry.StoredFile(
                    // bookmark 保存文件定位和可恢复的授权信息；它不是文件内容副本，之后仍需要解析并检查过期状态。
                    bookmarkData: try url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
                )
            }
            storedContent = .files(files)
        case let .color(value):
            storedContent = .color(value)
        case let .imagePNG(data, pixelWidth, pixelHeight):
            try FileManager.default.createDirectory(
                at: imageDirectory,
                withIntermediateDirectories: true
            )
            let fileName = "\(entry.id.uuidString).png"
            try data.write(
                to: safeImageURL(for: fileName),
                options: .atomic
            )
            storedContent = .imagePNG(
                fileName: fileName,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        }

        return StoredEntry(
            id: entry.id,
            capturedAt: entry.capturedAt,
            usageCount: entry.usageCount,
            isFavorite: entry.isFavorite,
            categoryID: entry.categoryID,
            fingerprint: entry.fingerprint,
            content: storedContent,
            sourceApplicationName: entry.sourceApplicationName,
            sourceBundleIdentifier: entry.sourceBundleIdentifier
        )
    }

    /// 与存储转换相反：读取图片或解析安全书签，恢复界面可直接使用的值对象。
    func materialize(_ stored: inout StoredEntry) throws -> ClipboardEntry {
        let content: ClipboardContent
        switch stored.content {
        case let .text(value):
            content = .text(value)
        case let .url(url):
            content = .url(url)
        case let .files(files):
            var urls: [URL] = []
            var accessedURLs: [URL] = []
            var refreshedFiles: [StoredEntry.StoredFile] = []
            do {
                for file in files {
                    // bookmarkDataIsStale 是输出参数，调用用 & 传入可写变量；过期时尝试生成新书签，不等于文件不存在。
                    var isStale = false
                    let url = try URL(
                        resolvingBookmarkData: file.bookmarkData,
                        options: [.withSecurityScope, .withoutUI],
                        relativeTo: nil,
                        bookmarkDataIsStale: &isStale
                    )
                    if url.startAccessingSecurityScopedResource() { accessedURLs.append(url) }
                    // 不做存在性淘汰：解析成功的 URL 可以在外置盘重新连接后恢复使用。
                    urls.append(url)
                    var refreshed: Data?
                    if isStale {
                        refreshed = try? url.bookmarkData(
                            options: .withSecurityScope,
                            includingResourceValuesForKeys: nil, relativeTo: nil
                        )
                    }
                    refreshedFiles.append(.init(bookmarkData: refreshed ?? file.bookmarkData))
                }
                guard !urls.isEmpty else {
                    throw AppFailure.invalidData(AppText.text("剪贴板文件引用无效"))
                }
            } catch {
                accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
                throw error
            }
            activeSecurityScopedURLs.removeValue(forKey: stored.id)?.forEach {
                $0.stopAccessingSecurityScopedResource()
            }
            activeSecurityScopedURLs[stored.id] = accessedURLs
            stored.content = .files(refreshedFiles)
            content = .files(urls)
        case let .color(value):
            content = .color(value)
        case let .imagePNG(fileName, pixelWidth, pixelHeight):
            // mappedIfSafe 请求在安全时使用内存映射；系统也可选择直接读取，不能假定一定延迟载入。
            let data = try Data(
                contentsOf: safeImageURL(for: fileName),
                options: .mappedIfSafe
            )
            content = .imagePNG(data, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        }

        return ClipboardEntry(
            id: stored.id,
            capturedAt: stored.capturedAt,
            usageCount: stored.usageCount ?? 1,
            isFavorite: stored.isFavorite ?? false,
            categoryID: stored.categoryID,
            fingerprint: stored.fingerprint,
            content: content,
            sourceApplicationName: stored.sourceApplicationName,
            sourceBundleIdentifier: stored.sourceBundleIdentifier
        )
    }

    /// atomic 写入类似先写临时文件再替换目标，避免中途失败留下半份 plist。
    func writeIndex() throws {
        do {
            try FileManager.default.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(StoredHistory(categories: categories, entries: storedEntries + unavailableEntries)).write(to: indexURL, options: .atomic)
        } catch {
            throw OperationFailure(category: .persistence, stage: "clipboard.index.write",
                message: error.localizedDescription, underlying: error)
        }
    }

    // 仅接受单个文件名而非任意相对路径，确保历史索引不能把读写目标带到图片目录以外。
    func safeImageURL(for fileName: String) throws -> URL {
        guard fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.isEmpty else {
            throw AppFailure.invalidData(AppText.text("剪贴板图片索引无效"))
        }
        return imageDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func defaultPersistenceDirectory() -> URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("isnipster", isDirectory: true)
            .appendingPathComponent("ClipboardLibrary", isDirectory: true)
    }
}

private extension ClipboardHistoryStore {
    /// 按仍保存在索引中的记录 ID 释放无主的 security scope，避免长期占用授权资源。
    func releaseUnusedAccess() {
        let liveIDs = Set(storedEntries.map(\.id))
        // 先复制 key 列表再删除原字典，避免迭代视图与集合修改交织；释放每条记录曾取得的授权。
        for id in Array(activeSecurityScopedURLs.keys) where !liveIDs.contains(id) {
            activeSecurityScopedURLs.removeValue(forKey: id)?.forEach {
                $0.stopAccessingSecurityScopedResource()
            }
        }
    }

    /// 重试恢复暂不可用记录；成功项按原采集时间插回，失败项继续保留待下次重试。
    func retryUnavailableEntries() {
        var remaining: [StoredEntry] = []
        for var stored in unavailableEntries {
            if let entry = try? materialize(&stored) {
                let index = entries.firstIndex { $0.capturedAt < entry.capturedAt } ?? entries.endIndex
                entries.insert(entry, at: index)
                storedEntries.insert(stored, at: index)
                totalBytes += entry.content.estimatedBytes
            } else {
                remaining.append(stored)
            }
        }
        unavailableEntries = remaining
    }

    /// 重新解析文件类记录的书签并刷新授权；同步更新内存 DTO 与磁盘 DTO，保持同下标对应。
    func refreshFileAccess() {
        for index in storedEntries.indices {
            guard case .files = storedEntries[index].content else { continue }
            var stored = storedEntries[index]
            if let entry = try? materialize(&stored) {
                totalBytes += entry.content.estimatedBytes - entries[index].content.estimatedBytes
                entries[index] = entry
                storedEntries[index] = stored
            }
        }
    }

    /// 删除前再次确认文件未被有效或暂不可用记录引用；失败记警告，交给后续维护处理。
    func removeImages(named fileNames: [String]) {
        let referenced = Set((storedEntries + unavailableEntries).compactMap(\.imageFileName))
        for name in Set(fileNames) where !referenced.contains(name) {
            do {
                try FileManager.default.removeItem(at: safeImageURL(for: name))
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
            } catch {
                AppDiagnostics.failure(error, stage: "clipboard.cleanup")
                cleanupWarning = "历史记录已更新，但部分图片清理失败，将自动重试：\(error.localizedDescription)"
            }
        }
    }

    /// 仅清理符合本项目命名规则且没有索引引用的 PNG；目录不存在不算清理失败。
    func cleanupOrphanedImages() {
        cleanupWarning = nil
        let referenced = Set((storedEntries + unavailableEntries).compactMap(\.imageFileName))
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: imageDirectory, includingPropertiesForKeys: nil
            )
            for url in files where url.pathExtension == "png"
                && UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
                && !referenced.contains(url.lastPathComponent) {
                do { try FileManager.default.removeItem(at: url) }
                catch {
                    AppDiagnostics.failure(error, stage: "clipboard.cleanup")
                    cleanupWarning = "历史记录已更新，但部分图片清理失败，将自动重试：\(error.localizedDescription)"
                }
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            // 尚未保存过图片，无目录可清理。
        } catch {
            AppDiagnostics.failure(error, stage: "clipboard.cleanup")
            cleanupWarning = "无法清理历史图片，将自动重试：\(error.localizedDescription)"
        }
    }
}

private extension ClipboardHistoryStore {
    struct StoredHistory: Codable {
        var categories: [ClipboardCategory]
        var entries: [StoredEntry]
    }

    /// 磁盘索引使用的轻量剪贴板条目，不直接内嵌图片字节。
    struct StoredEntry: Codable, Equatable {
        /// 通过安全书签持久化的文件引用。
        struct StoredFile: Codable, Equatable {
            let bookmarkData: Data
        }

        /// 可写入本地索引的剪贴板内容表示。
        enum Content: Codable, Equatable {
            case text(String)
            case url(URL)
            case imagePNG(fileName: String, pixelWidth: Int, pixelHeight: Int)
            case files([StoredFile])
            case color(String)
        }

        let id: UUID
        let capturedAt: Date
        var usageCount: Int?
        var isFavorite: Bool?
        var categoryID: UUID?
        let fingerprint: String
        var content: Content
        let sourceApplicationName: String?
        let sourceBundleIdentifier: String?

        var imageFileName: String? {
            guard case let .imagePNG(fileName, _, _) = content else { return nil }
            return fileName
        }
    }
}
