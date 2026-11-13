import MacShared
import MacPreferences
// 阅读路线
// ClipboardFilter 判定条目类型，FilterButtonContent 只显示标签与悬停反馈。
// 有限筛选项用 enum 穷举，比多个容易组合出非法状态的 Bool 更直观。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import ClipboardFeature
import Combine
import SwiftUI
import iSnipsterCore

enum ClipboardSortOrder: String, CaseIterable, Identifiable {
    case newest
    case mostUsed

    var id: Self { self }

    var title: String {
        switch self {
        case .newest: AppText.text("按照时间排序")
        case .mostUsed: AppText.text("按照次数排序")
        }
    }

    func sorted(_ entries: [ClipboardEntry]) -> [ClipboardEntry] {
        return entries.sorted { lhs, rhs in
            if self == .mostUsed, lhs.usageCount != rhs.usageCount {
                return lhs.usageCount > rhs.usageCount
            }
            if lhs.capturedAt != rhs.capturedAt {
                return lhs.capturedAt > rhs.capturedAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

}

/// 悬停状态留在单个按钮内部，避免鼠标横向移动时让整个历史列表随父视图状态
/// 一起重新计算，从而产生内容区闪动。
@MainActor
struct ClipboardFilterButtonContent: View {
    let title: String
    let icon: String
    let isSelected: Bool

    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State private var isHovered = false

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        Label(title, systemImage: icon)
            // 字重保持一致，避免选中后文字宽度改变并推挤整个分段按钮组。
            .font(ClipboardShelfMetrics.font(.callout.weight(.medium)))
            .foregroundStyle(Color.primary)
            .lineLimit(1)
            // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
            .padding(.horizontal, 10)
            // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
            .frame(height: ClipboardShelfMetrics.scaled(30))
            // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
            .background {
                if isHovered && !isSelected {
                    Capsule()
                        .fill(Color.primary.opacity(0.065))
                        .transition(.opacity)
                }
            }
            .contentShape(Capsule())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    isHovered = hovering
                }
            }
    }
}

/// 剪贴板时间线内置的内容类型筛选条件。
enum ClipboardFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case text
    case image
    case link
    case file
    case color

    var id: Self { self }

    var title: String {
        switch self {
        case .all: AppText.text("全部")
        case .favorites: AppText.text("收藏")
        case .text: AppText.text("文本")
        case .image: AppText.text("图片")
        case .link: AppText.text("链接")
        case .file: AppText.text("文件")
        case .color: AppText.text("颜色")
        }
    }

    var icon: String {
        switch self {
        case .all: "square.grid.2x2"
        case .favorites: "star.fill"
        case .text: "text.alignleft"
        case .image: "photo"
        case .link: "link"
        case .file: "doc"
        case .color: "paintpalette"
        }
    }

    /// 把筛选枚举转为对内容类型的判断；类型条件与搜索文本条件由上层组合。
    func matches(_ entry: ClipboardEntry) -> Bool {
        if self == .favorites { return entry.isFavorite }
        switch (self, entry.content) {
        case (.all, _), (.text, .text), (.image, .imagePNG), (.link, .url),
             (.file, .files), (.color, .color):
            return true
        default:
            return false
        }
    }
}
