import MacShared
import MacPreferences
// 阅读路线
// 卡片接收一条 Entry 和动作回调，按内容类型绘制预览；业务修改由父层处理。
// 悬停保留为卡片局部状态，减少整条时间线重算；Equatable 定义这类 View 的输入比较方式。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import ClipboardFeature
import SwiftUI
import iSnipsterCore

/// 展示一条剪贴板历史内容并承载点击、悬停和文件拖拽入口。
@MainActor
struct ClipboardEntryCard: View, Equatable {
    let entry: ClipboardEntry
    let quickPasteNumber: Int?
    let isSelected: Bool
    let cardHeight: CGFloat
    let onPrimaryClick: () -> Void
    let onPreview: () -> Void
    let onToggleFavorite: () -> Void
    let onDragCompleted: () -> Void
    let onHoverChange: (Bool) -> Void

    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State private var isHovered = false

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entry.id == rhs.entry.id
            && lhs.entry.isFavorite == rhs.entry.isFavorite
            && lhs.quickPasteNumber == rhs.quickPasteNumber
            && lhs.isSelected == rhs.isSelected
            && lhs.cardHeight == rhs.cardHeight
    }

    private var isHighlighted: Bool {
        isSelected || isHovered
    }

    private var headerHeight: CGFloat { ClipboardShelfMetrics.scaled(32) }
    private var headerAccessorySize: CGFloat { ClipboardShelfMetrics.scaled(24) }

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                cardHeader

                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.horizontal, 12)
                    .padding(.top, ClipboardShelfMetrics.scaled(4))
                    .padding(.bottom, ClipboardShelfMetrics.scaled(4))
            }
            .overlay {
                ClipboardCardInteraction(
                    entry: entry,
                    headerDragHeight: supportsFileDrag ? headerHeight : 0,
                    onClick: onPrimaryClick,
                    onDragCompleted: onDragCompleted
                )
            }
            .overlay(alignment: .topTrailing) {
                favoriteButton
                    .padding(.trailing, 10)
                    .padding(.top, (headerHeight - headerAccessorySize) / 2)
            }

            HStack(spacing: 6) {
                Text(contentSummary)
                    .font(ClipboardShelfMetrics.font(.caption2))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: onPrimaryClick)

                Button(action: onPreview) {
                    Image(systemName: "eye")
                        .font(ClipboardShelfMetrics.font(.caption))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: ClipboardShelfMetrics.scaled(22))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help(AppText.text("预览（空格键）"))
                .accessibilityLabel(AppText.text("预览"))
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .frame(height: ClipboardShelfMetrics.scaled(22))
        }
        .frame(width: 246, height: cardHeight)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.88),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
        .overlay {
            ClipboardPointingHandCursorRegion()
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    isHighlighted ? Color.accentColor : Color.primary.opacity(0.08),
                    lineWidth: isHighlighted ? 2 : 1
                )
                // 只控制是否参与交互命中，不改变绘制或布局；适合让进度提示、装饰边框透传鼠标。
                .allowsHitTesting(false)
        }
        .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        .onHover { hovering in
            isHovered = hovering
            onHoverChange(hovering)
        }
    }

    private var cardHeader: some View {
        HStack(spacing: 6) {
            HStack(spacing: 5) {
                Label(contentTypeTitle, systemImage: contentTypeIcon)
                    .font(ClipboardShelfMetrics.font(.caption.weight(.semibold)))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: true, vertical: false)

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(relativeTimeText(at: context.date))
                        .font(ClipboardShelfMetrics.font(.caption2))
                        .foregroundStyle(.white.opacity(0.78))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                if let quickPasteNumber {
                    Text("⌘\(quickPasteNumber)")
                        .font(ClipboardShelfMetrics.font(.caption2.monospacedDigit().weight(.semibold)))
                        .foregroundStyle(.white.opacity(0.92))
                        .frame(width: headerAccessorySize, height: headerAccessorySize)
                        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                        .accessibilityLabel(AppText.format("快速粘贴 Command %d", quickPasteNumber))
                }

                sourceIcon(size: ClipboardShelfMetrics.scaled(18))
                    .frame(width: headerAccessorySize, height: headerAccessorySize)
                    .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    .help(entry.sourceApplicationName ?? AppText.text("未知来源"))

                // 收藏按钮放在鼠标交互层上方，此处预留相同的方形空间。
                Color.clear
                    .frame(width: headerAccessorySize, height: headerAccessorySize)
            }
            .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity)
        .frame(height: headerHeight)
        .background(
            contentTypeColor,
            in: UnevenRoundedRectangle(
                topLeadingRadius: 16,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 16,
                style: .continuous
            )
        )
    }

    private var favoriteButton: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: entry.isFavorite ? "star.fill" : "star")
                .font(ClipboardShelfMetrics.font(.system(size: 12, weight: .semibold)))
                .foregroundStyle(entry.isFavorite ? Color.yellow : Color.white.opacity(0.92))
                .frame(width: headerAccessorySize, height: headerAccessorySize)
                .background(
                    entry.isFavorite ? Color.black.opacity(0.18) : Color.white.opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(AppText.text(entry.isFavorite ? "取消收藏" : "收藏"))
        .accessibilityLabel(AppText.text(entry.isFavorite ? "取消收藏" : "收藏"))
    }

    /// 用传入的当前时刻计算相对时间，卡片的数据身份仍取自原记录。
    private func relativeTimeText(at currentDate: Date) -> String {
        let elapsed = max(0, currentDate.timeIntervalSince(entry.capturedAt))
        let minutes = Int(elapsed / 60)
        let hours = Int(elapsed / 3_600)
        let days = Int(elapsed / 86_400)

        if minutes < 1 {
            return AppText.text("刚刚")
        } else if hours < 1 {
            return AppText.format("%d 分钟前", minutes)
        } else if days < 1 {
            return AppText.format("%d 小时前", hours)
        } else if days < 30 {
            return AppText.format("%d 天前", days)
        } else {
            return AppText.format("%d 个月前", max(1, days / 30))
        }
    }

    private var contentSummary: String {
        switch entry.content {
        case let .text(value):
            return AppText.format("%d 个字符", value.count)
        case let .url(url):
            return url.host ?? AppText.text("链接")
        case let .imagePNG(_, width, height):
            return "\(width) × \(height)"
        case let .files(urls):
            return AppText.format("%d 个文件", urls.count)
        case let .color(value):
            return value
        }
    }

    private var contentTypeColor: Color {
        switch entry.content {
        case .text:
            return Color(red: 0.27, green: 0.60, blue: 0.91)
        case .url:
            return Color(red: 0.39, green: 0.36, blue: 0.84)
        case .imagePNG:
            return Color(red: 0.42, green: 0.48, blue: 0.55)
        case .files:
            return Color(red: 0.93, green: 0.55, blue: 0.17)
        case .color:
            return Color(red: 0.84, green: 0.32, blue: 0.56)
        }
    }

    // @ViewBuilder 是结果构建器：把闭包内的多个 View 和条件分支组合成一个静态类型的视图结果。
    @ViewBuilder
    /// 根据内容类型选择预览，类似 Vue template 中的 v-if 分支；frame 和缩放只影响展示。
    private var preview: some View {
        switch entry.content {
        case let .text(value):
            nonWrappingText(
                value,
                font: ClipboardShelfMetrics.font(.system(.body, design: .monospaced))
            )
        case let .url(url):
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "link.circle.fill")
                    .font(ClipboardShelfMetrics.font(.title2))
                    .foregroundStyle(Color(nsColor: .linkColor))
                Text(url.host ?? url.absoluteString)
                    .font(ClipboardShelfMetrics.font(.headline))
                    .foregroundStyle(Color(nsColor: .linkColor))
                    .lineLimit(1)
                nonWrappingText(
                    url.absoluteString,
                    font: ClipboardShelfMetrics.font(.caption)
                )
                    .foregroundStyle(Color.accentColor.opacity(0.85))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .help(AppText.text("按住 Command 点击，在默认浏览器中打开"))
        case let .imagePNG(data, _, _):
            if let image = ClipboardCardAssetCache.image(for: entry.id, data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                Image(systemName: "photo.badge.exclamationmark")
            }
        case let .files(urls):
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "doc.on.doc.fill")
                    .font(ClipboardShelfMetrics.font(.title2))
                    .foregroundStyle(.orange)
                Text(urls.count == 1 ? AppText.text("1 个文件") : AppText.format("%d 个文件", urls.count))
                    .font(ClipboardShelfMetrics.font(.headline))
                    .lineLimit(1)
                nonWrappingText(
                    urls.map(\.lastPathComponent).joined(separator: "\n"),
                    font: ClipboardShelfMetrics.font(.caption)
                )
                    .foregroundStyle(.secondary)
            }
        case let .color(value):
            VStack(alignment: .leading, spacing: 8) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hexString: value) ?? .clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color(nsColor: .separatorColor))
                    )
                Text(value)
                    .font(ClipboardShelfMetrics.font(.body.monospaced().weight(.semibold)))
                    .lineLimit(1)
            }
        }
    }

    private func nonWrappingText(_ value: String, font: Font) -> some View {
        GeometryReader { geometry in
            Text(verbatim: value)
                .font(font)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: true, vertical: true)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
        }
    }

    @ViewBuilder
    /// 优先显示来源应用图标；无法取得时由此展示兜底内容，不影响记录可用性。
    private func sourceIcon(size: CGFloat) -> some View {
        if let bundleIdentifier = entry.sourceBundleIdentifier,
           let applicationIcon = ClipboardCardAssetCache.applicationIcon(
            bundleIdentifier: bundleIdentifier
           ) {
            Image(nsImage: applicationIcon)
                .resizable()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "app")
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: size, height: size)
        }
    }

    private var contentTypeTitle: String {
        switch entry.content {
        case .text: AppText.text("文本")
        case .url: AppText.text("链接")
        case .imagePNG: AppText.text("图片")
        case .files: AppText.text("文件")
        case .color: AppText.text("颜色")
        }
    }

    private var supportsFileDrag: Bool {
        switch entry.content {
        case .imagePNG, .files:
            return true
        case .text, .url, .color:
            return false
        }
    }

    private var contentTypeIcon: String {
        switch entry.content {
        case .text: "text.alignleft"
        case .url: "link"
        case .imagePNG: "photo"
        case .files: "doc.on.doc"
        case .color: "paintpalette"
        }
    }
}

private extension Color {
    init?(hexString: String) {
        let cleaned = hexString.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
