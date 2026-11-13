// 阅读路线
// Policy 是配置快照，Storing 才是存储协议；Controller 发命令，MacPlatform 的 actor 完成落盘。
// 方法返回更新后的完整列表，调用方据此发布 UI 状态，而非先假设磁盘提交已经成功。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import Foundation

/// 历史记录策略值：是否采集、允许的内容类型、去重开关及数量/天数上限。
public struct ClipboardHistoryPolicy: Sendable, Equatable {
    public let recordsHistory: Bool
    public let maximumItems: Int
    public let retentionDays: Int?
    public let recordsText: Bool
    public let recordsImages: Bool
    public let recordsFiles: Bool
    public let recordsColors: Bool
    public let removesDuplicates: Bool

    public init(
        recordsHistory: Bool,
        maximumItems: Int,
        retentionDays: Int?,
        recordsText: Bool,
        recordsImages: Bool,
        recordsFiles: Bool,
        recordsColors: Bool,
        removesDuplicates: Bool
    ) {
        self.recordsHistory = recordsHistory
        self.maximumItems = max(1, maximumItems)
        // Optional.flatMap 在有值时校验并返回新的 Optional；不合法天数归一为 nil，表示不按天数淘汰。
        self.retentionDays = retentionDays.flatMap { $0 > 0 ? $0 : nil }
        self.recordsText = recordsText
        self.recordsImages = recordsImages
        self.recordsFiles = recordsFiles
        self.recordsColors = recordsColors
        self.removesDuplicates = removesDuplicates
    }
}

/// 定义剪贴板历史的加载、保存、删除和清空能力。
public protocol ClipboardHistoryStoring: Sendable {
    func maintenanceWarning() async -> String?
    func allEntries(policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot

    @discardableResult
    func insert(
        _ snapshot: ClipboardSnapshot,
        policy: ClipboardHistoryPolicy
    ) async throws -> ClipboardHistorySnapshot

    func apply(policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot

    func updateCategory(_ mutation: ClipboardCategoryMutation, policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot
    func clear() async throws -> ClipboardHistorySnapshot
    func remove(id: UUID, policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot
    func markUsed(id: UUID, policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot
    func toggleFavorite(id: UUID, policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot
    func clearFavorites(policy: ClipboardHistoryPolicy) async throws -> ClipboardHistorySnapshot
}

public extension ClipboardHistoryStoring {
    func maintenanceWarning() async -> String? { nil }
}
