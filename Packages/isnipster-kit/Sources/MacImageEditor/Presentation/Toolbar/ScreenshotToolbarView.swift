import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 按钮发出 ScreenshotToolbarAction，控制器统一处理；工具栏不自己启动 OCR 或导出任务。
// 动作 enum 类似 TS 事件联合类型，关联值携带工具/颜色格式，避免分散的字符串事件名。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import ColorPickerFeature
import ImageEditorFeature
import Observation
import SwiftUI
import iSnipsterCore

/// 主工具栏只负责展示和发送用户意图，截图流程由外层会话控制器统一编排。
enum ScreenshotToolbarAction {
    case selectTool(EditorTool)
    case smartRedaction
    case ocr
    case translation
    case startTranslation
    case pin
    case copyFile
    case undo
    case redo
    case cancel
    case copy
    case copySampledColor(ColorFormat)
}

/// 微信/iShot 风格的紧凑工具条：工具在左，完成类操作在右，确认即复制并退出。
@MainActor
struct ScreenshotToolbarView: View {
    // @Bindable 为 @Observable 对象生成 $属性 绑定，类似 v-model 通道；对象的创建和共享仍由外层负责。
    @Bindable var session: InlineEditorSession
    let shortcuts: [ScreenshotToolShortcutAction: HotKeyDescriptor]
    let onAction: (ScreenshotToolbarAction) -> Void
    let onHoverHint: (String?) -> Void

    private var document: ImageDocument { session.document }
    private let toolSpacing: CGFloat = 5

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        ScrollView(.horizontal) {
            // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
            HStack(spacing: 9) {
                drawingTools.disabled(session.isProcessing)
                Divider().frame(width: 1, height: 26)
                recognitionTools.disabled(session.isProcessing)
                Divider().frame(width: 1, height: 26)
                completionTools
            }
            // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .screenshotToolbarChrome()
        .onExitCommand { onAction(.cancel) }
    }

    private var drawingTools: some View {
        HStack(spacing: toolSpacing) {
            toolButton(.rectangle)
            toolButton(.arrow)
            toolButton(.pen)
            toolButton(.text)
            toolButton(.step)
            commandButton(
                AppText.text(.screenshotTranslation),
                icon: .translation,
                shortcutAction: .translation,
                isSelected: session.showsTranslationOptions,
                action: { onAction(.translation) }
            )
        }
    }

    private var recognitionTools: some View {
        HStack(spacing: toolSpacing) {
            ocrButton
            toolButton(.colorPicker)
            redactionButton
        }
    }

    private var completionTools: some View {
        HStack(spacing: toolSpacing) {
            actionButton(AppText.text(.pin), icon: .pin, shortcutAction: .pin, action: { onAction(.pin) })
            actionButton(AppText.text(.undo), icon: .undo, shortcutAction: .undo, action: { onAction(.undo) })
            actionButton(AppText.text(.redo), icon: .redo, shortcutAction: .redo, action: { onAction(.redo) })
            actionButton(
                AppText.text(.copyFile),
                icon: .save,
                shortcutAction: .copyFile,
                action: { onAction(.copyFile) }
            )
            actionButton(AppText.text(.cancel), icon: .cancel, shortcutAction: .cancel, action: { onAction(.cancel) })

            Button { onAction(.copy) } label: {
                ScreenshotToolbarIcon(.confirm)
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
                    .foregroundStyle(Color.primary)
            }
            .buttonStyle(.plain)
            // 为 VoiceOver 提供语义标签；只有图标时尤其需要，不能只靠鼠标悬停提示表达动作。
            .disabled(session.isProcessing)
            .accessibilityLabel(AppText.text(.finishAndCopy))
            .accessibilityHint(AppText.text(.copyAndExitHint))
            .onHover { isHovering in
                onHoverHint(isHovering ? shortcutHelp(.copy, title: AppText.text(.finishAndCopy)) : nil)
            }

        }
    }

    /// 绘制持续选中的工具按钮，并把选择动作上抛；点击工具不直接在此生成绘图命令。
    private func toolButton(_ tool: EditorTool) -> some View {
        let isSelected = !session.isOCRMode
            && !session.isAdjustingSelection
            && document.selectedTool == tool
        let tint = isSelected ? Color.accentColor : Color.primary
        return Button {
            onAction(.selectTool(tool))
        } label: {
            ScreenshotToolbarIcon(toolbarSymbol(for: tool))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
                .background(
                    isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tool.title)
        .accessibilityHint(shortcutHelp(toolShortcutAction(for: tool), title: tool.title))
        .onHover { isHovering in
            onHoverHint(
                isHovering
                    ? shortcutHelp(toolShortcutAction(for: tool), title: tool.title)
                    : nil
            )
        }
    }

    private func commandButton(
        _ title: String,
        icon: ScreenshotToolbarIcon.Symbol,
        shortcutAction: ScreenshotToolShortcutAction? = nil,
        isSelected: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ScreenshotToolbarIcon(icon)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .background(
                    isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .disabled(session.isProcessing && shortcutAction != .cancel)
        .accessibilityLabel(title)
        .accessibilityHint(shortcutHelp(shortcutAction, title: title))
        .onHover { isHovering in
            onHoverHint(isHovering ? shortcutHelp(shortcutAction, title: title) : nil)
        }
    }

    private var redactionButton: some View {
        let isSelected = !session.isOCRMode
            && !session.isAdjustingSelection
            && document.selectedTool == .redaction
        let tint: Color = isSelected ? .accentColor : .primary
        return Button {
            onAction(.smartRedaction)
        } label: {
            ScreenshotToolbarIcon(.redaction)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .background(
                    isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppText.text(.redact))
        .accessibilityHint(
            shortcutHelp(.redaction, title: AppText.text(.redact))
                + AppText.text("：自动识别后可继续拖动补充；单击已有色块可取消")
        )
        .onHover { isHovering in
            onHoverHint(isHovering ? shortcutHelp(.redaction, title: AppText.text(.redact)) : nil)
        }
    }

    private var ocrButton: some View {
        let isSelected = session.isOCRMode
        return Button { onAction(.ocr) } label: {
            ScreenshotToolbarIcon(.ocr)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
                .background(
                    isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AppText.text(.ocr))
        .accessibilityHint(shortcutHelp(.ocr, title: AppText.text(.ocrHint)))
        .onHover { isHovering in
            onHoverHint(isHovering ? shortcutHelp(.ocr, title: AppText.text(.ocr)) : nil)
        }
    }

    /// 将绘图工具映射到快捷动作目录，让提示文案与键盘配置使用同一个动作标识。
    private func toolShortcutAction(for tool: EditorTool) -> ScreenshotToolShortcutAction {
        switch tool {
        case .rectangle: .rectangle
        case .arrow: .arrow
        case .pen: .pen
        case .redaction: .redaction
        case .text: .text
        case .step: .step
        case .colorPicker: .colorPicker
        }
    }

    /// 把工具语义映射到 Lucide 图标枚举，资源命名集中在 ScreenshotToolbarIcon。
    private func toolbarSymbol(for tool: EditorTool) -> ScreenshotToolbarIcon.Symbol {
        switch tool {
        case .rectangle: .rectangle
        case .arrow: .arrow
        case .pen: .pen
        case .text: .text
        case .step: .step
        case .colorPicker: .colorPicker
        case .redaction: .redaction
        }
    }

    /// 把动作说明与当前配置的键位组合为悬停提示，不硬编码另一套快捷键默认值。
    private func shortcutHelp(
        _ action: ScreenshotToolShortcutAction?,
        title: String
    ) -> String {
        guard let action else { return title }
        let descriptor = shortcuts[action] ?? action.defaultDescriptor
        return "\(title)（\(ScreenshotToolShortcutDisplay.string(for: descriptor))）"
    }

    private func actionButton(
        _ title: String,
        icon: ScreenshotToolbarIcon.Symbol,
        shortcutAction: ScreenshotToolShortcutAction,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ScreenshotToolbarIcon(icon)
                .foregroundStyle(Color.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(session.isProcessing && shortcutAction != .cancel)
        .accessibilityLabel(title)
        .accessibilityHint(shortcutHelp(shortcutAction, title: title))
        .onHover { isHovering in
            onHoverHint(isHovering ? shortcutHelp(shortcutAction, title: title) : nil)
        }
    }
}
