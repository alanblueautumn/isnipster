import Foundation

public struct ClipboardCategory: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let name: String

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

public struct ClipboardHistorySnapshot: Sendable, Equatable {
    public let entries: [ClipboardEntry]
    public let categories: [ClipboardCategory]

    public init(entries: [ClipboardEntry] = [], categories: [ClipboardCategory] = []) {
        self.entries = entries
        self.categories = categories
    }
}

public enum ClipboardCategoryMutation: Sendable {
    case create(ClipboardCategory)
    case remove(UUID)
    case assign(entryID: UUID, categoryID: UUID?)
}
