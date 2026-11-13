import MacShared
import MacPreferences
// 阅读路线
// 将过滤结果组成横向滚动卡片，连接选择、拖拽和键盘定位。
// 条目 ID 相当于 Vue :key；重排后仍能定位同一记录，不能以可变数组下标充当身份。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import ClipboardFeature
import Combine
import SwiftUI
import iSnipsterCore

extension ClipboardHistoryView {
    // @ViewBuilder 是结果构建器：把闭包内的多个 View 和条件分支组合成一个静态类型的视图结果。
    @ViewBuilder
    /// 时间线组合滚动容器与卡片；selectedID 用稳定身份追踪选择，不能保存容易变化的数组下标。
    var timeline: some View {
        if visibleEntries.isEmpty {
            let showsFavoriteHint = selectedCustomCategoryID == nil
                && filter == .favorites && controller.query.isEmpty
            ContentUnavailableView(
                controller.query.isEmpty
                    ? AppText.text(showsFavoriteHint ? "暂无收藏" : "暂无剪贴板内容")
                    : AppText.text("没有匹配结果"),
                systemImage: controller.query.isEmpty
                    ? (showsFavoriteHint ? "star" : "clipboard") : "magnifyingglass",
                description: Text(AppText.text(showsFavoriteHint
                    ? "点击卡片顶部的星标按钮即可收藏"
                    : "复制文本、链接、图片或文件后会自动出现在这里"))
            )
            // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
                            ForEach(Array(visibleEntries.enumerated()), id: \.element.id) { index, entry in
                                ClipboardEntryCard(
                                    entry: entry,
                                    quickPasteNumber: index < 9 ? index + 1 : nil,
                                    isSelected: selectedID == entry.id,
                                    cardHeight: max(0, geometry.size.height - 10),
                                    onPrimaryClick: { handleCardClick(entry) },
                                    onPreview: { previewEntry(entry) },
                                    onToggleFavorite: { controller.toggleFavorite(entry) },
                                    onDragCompleted: { controller.markUsed(entry) },
                                    onHoverChange: { isHovering in
                                        if isHovering {
                                            hoverSelection.hoveredID = entry.id
                                            selectedID = entry.id
                                        } else if hoverSelection.hoveredID == entry.id {
                                            hoverSelection.hoveredID = nil
                                        }
                                    }
                                )
                                .equatable()
                                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .focusable(false)
                                // 显式指定视图身份；值变化可让 SwiftUI 重建该子树的局部状态，不只是换一个显示标签。
                                .id(entry.id)
                                .contextMenu {
                                    Button(AppText.text("粘贴")) { onPaste(entry, false) }
                                    if entry.content.plainTextValue != nil {
                                        Button(AppText.text("粘贴为纯文本")) { onPaste(entry, true) }
                                    }
                                    Divider()
                                    Button(AppText.text("仅复制到系统剪贴板")) { onCopy(entry, false) }
                                    if !customCategories.isEmpty {
                                        Menu(AppText.text("加入分类"), systemImage: "tag") {
                                            ForEach(customCategories) { category in
                                                Button {
                                                    assign(entry, to: category)
                                                } label: {
                                                    if assignedCategoryID(for: entry) == category.id {
                                                        Label(category.name, systemImage: "checkmark")
                                                    } else {
                                                        Text(category.name)
                                                    }
                                                }
                                            }
                                            if assignedCategoryID(for: entry) != nil {
                                                Divider()
                                                Button(AppText.text("移出分类")) {
                                                    removeEntryFromCategory(entry)
                                                }
                                            }
                                        }
                                    }
                                    Button(AppText.text("删除"), role: .destructive) { deleteEntry(entry) }
                                }
                            }
                        }
                        // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
                        .padding(.horizontal, 16)
                        .padding(.vertical, 5)
                        .frame(maxHeight: .infinity, alignment: .top)
                        // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
                        .background(HorizontalMouseWheelSupport())
                    }
                    // onChange 类似 Vue watch：状态变化后执行副作用；仅监听值变化，不代表每次 body 求值都会调用。
                    .onChange(of: selectedID) { _, newID in
                        guard let newID, hoverSelection.hoveredID == nil else { return }
                        withAnimation(.easeOut(duration: 0.14)) {
                            proxy.scrollTo(newID, anchor: .center)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
