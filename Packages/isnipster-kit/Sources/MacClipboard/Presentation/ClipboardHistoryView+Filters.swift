import MacShared
import MacPreferences
// 阅读路线
// 根视图的筛选栏和分类入口；选择内置类型或自定义分类后，由共享状态重新推导可见条目。
// 这些 computed View 是界面片段，extension 不会额外持有一份 controller。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import ClipboardFeature
import Combine
import SwiftUI
import iSnipsterCore

extension ClipboardHistoryView {
    var header: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        ZStack {
            HStack(spacing: 10) {
                searchField

                sortOrderButtons

                ScrollView(.horizontal) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)

                        HStack(spacing: 2) {
                            // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
                            ForEach(ClipboardFilter.allCases) { item in
                                filterButton(item)
                            }
                            ForEach(customCategories) { category in
                                customCategoryButton(category)
                            }
                        }
                        // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
                        .padding(3)
                        .isnipsterGlass(
                            Capsule(),
                            tint: Color.white.opacity(0.025),
                            interactive: true
                        )
                        // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
                        .background(Color.primary.opacity(0.07), in: Capsule())
                        .fixedSize(horizontal: true, vertical: false)

                        Spacer(minLength: 0)
                    }
                    // 分类较少时在固定视口内居中；分类增多后内容自然超过
                    // minWidth，并继续支持横向滚动。
                    .frame(minWidth: 560, alignment: .center)
                }
                .scrollIndicators(.hidden)
                .frame(width: 560)

                addCategoryButton
            }
            // 先按内容尺寸布局，再放到整条顶栏的正中。
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: .infinity, alignment: .center)

            trailingActions
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: ClipboardShelfMetrics.scaled(52), alignment: .center)
        .isnipsterGlassContainer(spacing: 10)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(AppText.text("搜索文本、链接、文件或图片"), text: $controller.query)
                .textFieldStyle(.plain)
                .autocorrectionDisabled(true)
                .writingToolsBehavior(.disabled)
                // 把此输入控件与 FocusState 关联，状态与原生输入焦点因此可以互相同步。
                .focused($searchIsFocused)
            if !controller.query.isEmpty {
                Button {
                    controller.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, ClipboardShelfMetrics.scaled(6))
        .frame(width: 360)
        .isnipsterGlass(
            RoundedRectangle(cornerRadius: 12, style: .continuous),
            tint: Color.white.opacity(0.04),
            interactive: true
        )
        .background(
            Color.primary.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var addCategoryButton: some View {
        Button {
            categoryName = ""
            isAddingCategory = true
        } label: {
            Image(systemName: "plus")
                .font(ClipboardShelfMetrics.font(.body.weight(.medium)))
                .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .frame(width: ClipboardShelfMetrics.scaled(30), height: ClipboardShelfMetrics.scaled(30))
        .isnipsterGlass(Circle(), tint: Color.white.opacity(0.025), interactive: true)
        .help(AppText.text("添加分类"))
        .popover(isPresented: $isAddingCategory, arrowEdge: .bottom) {
            categoryCreator
        }
    }

    private var sortOrderButtons: some View {
        HStack(spacing: 2) {
            ForEach(ClipboardSortOrder.allCases) { order in
                sortOrderButton(order)
            }
        }
        .padding(3)
        .isnipsterGlass(
            Capsule(),
            tint: Color.white.opacity(0.025),
            interactive: true
        )
        .background(Color.primary.opacity(0.07), in: Capsule())
        .fixedSize(horizontal: true, vertical: false)
    }

    private func sortOrderButton(_ order: ClipboardSortOrder) -> some View {
        let isSelected = sortOrder == order
        return Button {
            withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                sortOrder = order
            }
        } label: {
            ClipboardFilterButtonContent(
                title: order.title,
                icon: order == .newest ? "clock" : "arrow.down.square",
                isSelected: isSelected
            )
            .background {
                if isSelected {
                    selectionIndicator(in: sortSelectionNamespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var trailingActions: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                if let error = controller.persistenceErrorMessage {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(error)
                }

                Text(AppText.format(.itemCount, visibleEntries.count))
                    .font(ClipboardShelfMetrics.font(.caption.monospacedDigit()))
                    .foregroundStyle(.secondary)
            }

            Button {
                controller.clearFavorites()
            } label: {
                Image(systemName: "star.slash")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .frame(width: ClipboardShelfMetrics.scaled(28), height: ClipboardShelfMetrics.scaled(28))
            .isnipsterGlass(Circle(), tint: Color.white.opacity(0.025), interactive: true)
            .modifier(ClipboardActionHoverBackground(isDestructive: true))
            .help(AppText.text("取消全部收藏"))
            .accessibilityLabel(AppText.text("取消全部收藏"))

            Button {
                controller.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .focusable(false)
            .frame(width: ClipboardShelfMetrics.scaled(28), height: ClipboardShelfMetrics.scaled(28))
            .isnipsterGlass(Circle(), tint: Color.white.opacity(0.025), interactive: true)
            .modifier(ClipboardActionHoverBackground(isDestructive: true))
            .help(AppText.text("清空剪贴板历史"))

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .focusable(false)
            .frame(width: ClipboardShelfMetrics.scaled(28), height: ClipboardShelfMetrics.scaled(28))
            .isnipsterGlass(Circle(), tint: Color.white.opacity(0.025), interactive: true)
            .modifier(ClipboardActionHoverBackground())
            .help(AppText.text("关闭"))
        }
    }

    private func filterButton(_ item: ClipboardFilter) -> some View {
        let isSelected = selectedCustomCategoryID == nil && filter == item
        return Button {
            withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                selectedCustomCategoryID = nil
                filter = item
            }
        } label: {
            ClipboardFilterButtonContent(
                title: item.title,
                icon: item.icon,
                isSelected: isSelected
            )
                .background {
                    if isSelected {
                        selectionIndicator(in: filterSelectionNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
    }

    private func customCategoryButton(_ category: ClipboardCategory) -> some View {
        let isSelected = selectedCustomCategoryID == category.id
        return Button {
            withAnimation(.snappy(duration: 0.32, extraBounce: 0.04)) {
                selectedCustomCategoryID = category.id
            }
        } label: {
            ClipboardFilterButtonContent(
                title: category.name,
                icon: "tag.fill",
                isSelected: isSelected
            )
                .background {
                    if isSelected {
                        selectionIndicator(in: filterSelectionNamespace)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
        .contextMenu {
            Button(AppText.text("删除分类"), systemImage: "trash", role: .destructive) {
                removeCategory(category)
            }
        }
    }

    // @ViewBuilder 是结果构建器：把闭包内的多个 View 和条件分支组合成一个静态类型的视图结果。
    @ViewBuilder
    private func selectionIndicator(in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) {
            ZStack {
                Capsule()
                    .fill(Color.blue.opacity(0.18))

                Color.clear
                    .glassEffect(Glass.regular, in: Capsule())
                    .glassEffectID(
                        "clipboard-filter-selection-glass",
                        in: namespace
                    )
                    .glassEffectTransition(.matchedGeometry)
            }
            .matchedGeometryEffect(
                id: "clipboard-filter-selection-geometry",
                in: namespace
            )
            // 只控制是否参与交互命中，不改变绘制或布局；适合让进度提示、装饰边框透传鼠标。
            .allowsHitTesting(false)
        } else {
            Capsule()
                .fill(Color.blue.opacity(0.18))
                .matchedGeometryEffect(
                    id: "clipboard-filter-selection-geometry",
                    in: namespace
                )
                .allowsHitTesting(false)
        }
    }

    private var categoryCreator: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppText.text("添加分类"))
                .font(ClipboardShelfMetrics.font(.headline))
            TextField(AppText.text("分类名称"), text: $categoryName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(AppText.text(.cancel)) {
                    isAddingCategory = false
                }
                Button(AppText.text("添加")) {
                    addCategory()
                }
                .buttonStyle(.borderedProminent)
                // 通过环境向子控件传递禁用状态；这是交互限制，耗时任务入口仍需要自己的重复调用防护。
                .disabled(categoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .font(ClipboardShelfMetrics.font(.body))
        .padding(16)
        .frame(width: ClipboardShelfMetrics.scaled(260))
    }
}
