import MacShared
import MacPreferences
// 阅读路线
// 页面拥有搜索/分类/选中项等交互状态，Controller 拥有历史数据；激活动作交给 Presenter。
// @Bindable 提供 controller 属性的双向绑定，@State 保存当前页面自身的状态。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import ClipboardFeature
import Combine
import SwiftUI
import iSnipsterCore

/// 剪贴板时间线面板的 SwiftUI 根视图，协调筛选、选择和粘贴交互。
@MainActor
struct ClipboardHistoryView: View {
    // @Bindable 为 @Observable 对象生成 $属性 绑定，类似 v-model 通道；对象的创建和共享仍由外层负责。
    @Bindable var controller: ClipboardController
    let keyboardBridge: ClipboardKeyboardBridge
    let onPaste: (ClipboardEntry, Bool) -> Void
    let onCopy: (ClipboardEntry, Bool) -> Void
    let onOpenURL: (URL) -> Void
    let onPreview: (ClipboardEntry) -> Void
    let onDelete: (ClipboardEntry) -> Void
    let onClose: () -> Void

    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State var selectedID: ClipboardEntry.ID?
    @State var hoverSelection = ClipboardHoverSelection()
    @State var filter: ClipboardFilter = .all
    @AppStorage("isnipster.clipboard.sortOrder") var sortOrder = ClipboardSortOrder.newest
    var customCategories: [ClipboardCategory] { controller.categories }
    @State var selectedCustomCategoryID: UUID?
    @State var isAddingCategory = false
    @State var categoryName = ""
    @Namespace var filterSelectionNamespace
    @Namespace var sortSelectionNamespace
    // @FocusState 将焦点与状态绑定；修改值是在请求焦点变化，并不是改动文本内容。
    @FocusState var searchIsFocused: Bool

    var visibleEntries: [ClipboardEntry] {
        let filtered: [ClipboardEntry]
        if let categoryID = selectedCustomCategoryID {
            filtered = controller.filteredEntries.filter {
                $0.categoryID == categoryID
            }
        } else {
            filtered = controller.filteredEntries.filter(filter.matches)
        }
        return sortOrder.sorted(filtered)
    }

    private var selectedEntry: ClipboardEntry? {
        let activeID = hoverSelection.hoveredID ?? selectedID
        return visibleEntries.first(where: { $0.id == activeID })
    }

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(spacing: 0) {
            header
            timeline
        }
        .font(ClipboardShelfMetrics.font(.body))
        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 玻璃只放在背景层；原生 NSScrollView 不进入 glassEffect 的内容合成树。
        .background {
            let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
            ZStack {
                Color.clear.isnipsterGlass(
                    shape,
                    tint: Color.cyan.opacity(0.06)
                )
                shape.fill(
                    Color(nsColor: .windowBackgroundColor).opacity(0.72)
                )
            }
        }
        // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.8)
                // 只控制是否参与交互命中，不改变绘制或布局；适合让进度提示、装饰边框透传鼠标。
                .allowsHitTesting(false)
        }
        // 视图进入显示层级时执行，可重复触发；需要一次性语义的业务逻辑仍应由状态或服务保证。
        .onAppear {
            selectFirstVisibleEntry()
            searchIsFocused = true
        }
        // onChange 类似 Vue watch：状态变化后执行副作用；仅监听值变化，不代表每次 body 求值都会调用。
        .onChange(of: controller.categories) { _, categories in
            if let selectedCustomCategoryID, !categories.contains(where: { $0.id == selectedCustomCategoryID }) {
                self.selectedCustomCategoryID = nil
                filter = .all
            }
        }
        .onChange(of: visibleEntries.map(\.id)) { _, _ in
            // 过滤结果或排序变化后，快捷键选择与当前显示的第一项保持一致。
            selectFirstVisibleEntry()
        }
        // 订阅 Combine publisher 的事件，像订阅 RxJS 流；回调里更新状态后再由 SwiftUI 刷新界面。
        .onReceive(keyboardBridge.moveSelection) { offset in
            moveSelection(by: offset)
        }
        .onReceive(keyboardBridge.pasteSelection) { asPlainText in
            guard let selectedEntry else { return }
            onPaste(selectedEntry, asPlainText)
        }
        .onReceive(keyboardBridge.pasteIndex) { index in
            guard visibleEntries.indices.contains(index) else {
                return
            }
            activate(visibleEntries[index])
        }
        .onReceive(keyboardBridge.focusSearch) {
            searchIsFocused = true
        }
        .onReceive(keyboardBridge.previewSelection) {
            guard let selectedEntry else { return }
            previewEntry(selectedEntry)
        }
        .onExitCommand(perform: onClose)
        .onDeleteCommand {
            guard let selectedEntry else { return }
            deleteEntry(selectedEntry)
        }
        .onMoveCommand { direction in
            switch direction {
            case .left: moveSelection(by: -1)
            case .right: moveSelection(by: 1)
            default: break
            }
        }
    }

    func addCategory() {
        let name = categoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let category = ClipboardCategory(name: name)
        Task { @MainActor in
            do {
                try await controller.updateCategory(.create(category))
                selectedCustomCategoryID = category.id
                categoryName = ""
                isAddingCategory = false
            } catch {
                // Controller 发布持久化错误，创建失败时保留输入。
            }
        }
    }

    func removeCategory(_ category: ClipboardCategory) {
        Task { try? await controller.updateCategory(.remove(category.id)) }
    }

    func assignedCategoryID(for entry: ClipboardEntry) -> UUID? { entry.categoryID }

    func assign(_ entry: ClipboardEntry, to category: ClipboardCategory) {
        Task { try? await controller.updateCategory(.assign(entryID: entry.id, categoryID: category.id)) }
    }

    func removeEntryFromCategory(_ entry: ClipboardEntry) {
        Task { try? await controller.updateCategory(.assign(entryID: entry.id, categoryID: nil)) }
    }

    func deleteEntry(_ entry: ClipboardEntry) { onDelete(entry) }

    /// 根据当前过滤结果重置选中 ID；结果为空时自然变成 nil。
    private func selectFirstVisibleEntry() {
        selectedID = visibleEntries.first?.id
    }

    /// 预览按钮与空格键共享入口，预览时释放搜索框焦点。
    func previewEntry(_ entry: ClipboardEntry) {
        selectedID = entry.id
        searchIsFocused = false
        onPreview(entry)
    }

    /// 更新选中项并让搜索框释放焦点，然后通过回调执行普通粘贴。
    func activate(_ entry: ClipboardEntry) {
        selectedID = entry.id
        searchIsFocused = false
        onPaste(entry, false)
    }

    /// Cmd 点击 URL 时在浏览器打开并标记使用；其余点击走统一粘贴入口。
    func handleCardClick(_ entry: ClipboardEntry) {
        if case let .url(url) = entry.content,
           NSEvent.modifierFlags.contains(.command) {
            controller.markUsed(entry)
            onOpenURL(url)
            return
        }
        activate(entry)
    }

    /// 键盘导航在当前过滤结果内移动；搜索/分类会改变集合，所以每次从 selectedID 重新找位置。
    private func moveSelection(by offset: Int) {
        guard !visibleEntries.isEmpty else { return }
        guard let selectedID,
              let currentIndex = visibleEntries.firstIndex(where: { $0.id == selectedID }) else {
            selectFirstVisibleEntry()
            return
        }
        let nextIndex = min(max(currentIndex + offset, 0), visibleEntries.count - 1)
        self.selectedID = visibleEntries[nextIndex].id
        searchIsFocused = false
    }
}

/// 保存当前悬停卡片 ID，避免把高频悬停状态放入整棵 SwiftUI 视图树。
@MainActor
final class ClipboardHoverSelection {
    var hoveredID: ClipboardEntry.ID?
}
