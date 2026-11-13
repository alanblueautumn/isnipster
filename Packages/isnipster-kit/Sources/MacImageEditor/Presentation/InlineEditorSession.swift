import MacShared
import MacScreenshotSupport
import MacTranslation
import RecognitionFeature
// 阅读路线
// 保存选区阶段、当前拖动、文字草稿、OCR 选择和处理进度；文档只接收完成后的编辑命令。
// 类似 Vue 表单草稿与 Pinia 已提交数据分层，拖动每一帧不必进入撤销历史。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import CaptureFeature
import ClipboardFeature
import ColorPickerFeature
import ImageEditorFeature
import ImageTranslationFeature
import Observation
import iSnipsterCore
import SwiftUI
@preconcurrency import Translation

/// OCR 字符只服务于当前截图上的文本选择层，不属于图片编辑操作。
struct OCRInteractionCharacter: Identifiable {
    let id = UUID()
    let text: String
    let regionIndex: Int
    let normalizedRect: CGRect
}

/// 画布与工具栏共享的交互状态。操作仍然是矢量数据，拖动期间不会复制 Retina 位图。
///
/// 它类似 JavaFX/Swing Controller 的瞬时手势状态；ImageDocument 才是可撤销的领域状态。
@MainActor
@Observable
final class InlineEditorSession {
    let document: ImageDocument
    let cursorSession: ScreenshotCursorSession
    /// iShot 风格的初始状态：工具栏已经出现，但画布尚未锁定为标注模式。
    /// 用户可直接移动/缩放选区；选择第一个工具后切换为 false 且不再回退。
    var isAdjustingSelection = true
    // nil 表示没有进行中的拖动；有值时它固定首点，draftPoints 继续存末点或自由笔轨迹。
    var dragStart: CGPoint?
    var draftPoints: [CGPoint] = []
    /// 只保留本次编辑会话最近吸取的一个颜色值，不保存图片或取色历史。
    var sampledColor: SampledColor?
    /// 文本工具的输入草稿。落点使用原图像素坐标，保证画布缩放后导出位置不变。
    var textValue = ""
    /// 仅影响光标，文字移动的预览和提交仍由原画布手势负责。
    var isMovingText = false
    var textEntryOrigin: CGPoint?
    // 每次新文字输入生成不同 ID；迟到的失焦回调必须匹配这个 ID 才能提交当前草稿。
    var textEntryID: UUID?
    /// 输入框去掉 padding 后的实际排版尺寸，用于让提交结果保持相同的换行和高度。
    var textEntryDisplayContentSize: CGSize?
    /// 用户看到的逻辑字号；提交时按画布与原图比例换算为图片像素字号。
    var textFontSize: CGFloat = 20
    private var textEntryImageScale: CGFloat = 1
    /// 每张截图最多自动扫描一次；扫描后仍保持打码工具，可继续手工拖框。
    var hasRequestedAutomaticRedaction = false
    var operationState: EditorOperationState = .idle
    var isProcessing: Bool { operationState != .idle }
    /// 翻译参数仅属于本次截图，不修改全局设置；点击主工具时按这些参数立即翻译。
    var showsTranslationOptions = false
    var translationSourceLanguage = TranslationLanguage.defaultScreenshotLanguages.sourceLanguage
    var translationTargetLanguage = TranslationLanguage.defaultScreenshotLanguages.targetLanguage
    /// 智能打码允许用户边等待边补框；OCR 复制和图片翻译则保持画布只读。
    var allowsCanvasEditingWhileProcessing: Bool { operationState.allowsCanvasEditing }
    /// 长任务的选区中央反馈；nil 时完全不创建覆盖视图，也不占用鼠标事件。
    var centeredProgressMessage: String? { operationState.progressMessage }
    var errorMessage: String?
    var ocrCharacters: [OCRInteractionCharacter] = []
    /// OCR 字符已经按阅读顺序存放，连续文本选择只需要保存首尾索引。
    /// 避免全文字截图拖选时反复创建包含数千个 UUID 的 Set。
    // ClosedRange 的上下界都包含；例如 2...4 选中 3 个字符，区别于数组常用的 2..<4。
    var selectedOCRCharacterRange: ClosedRange<Int>?
    var isOCRMode: Bool { !ocrCharacters.isEmpty }

    init(document: ImageDocument, cursorSession: ScreenshotCursorSession) {
        self.document = document
        self.cursorSession = cursorSession
    }

    /// 光标命中使用左上原点的画布坐标；OCR 优先于工具，正在输入时由文本编辑器接管。
    func cursorContext(at location: CGPoint, canvasSize: CGSize) -> ScreenshotCursorContext {
        if isOCRMode { return .ocrText }
        if isMovingText { return .movingText }
        if document.selectedTool == .text {
            if textEntryOrigin != nil { return .textInput }
            if committedTextRegion(at: location, canvasSize: canvasSize) != nil { return .textAnnotation }
        }
        return document.selectedTool == .text ? .textInput : .drawing
    }

    // 从最后一条文字操作反向命中实际字形边界，避免点击排版空白区也拖动文字；重叠时优先最上层。
    func committedTextRegion(
        at location: CGPoint,
        canvasSize: CGSize
    ) -> (id: UUID, rect: CGRect, visibleBounds: CGRect)? {
        guard canvasSize.width > 0, canvasSize.height > 0,
              document.imageSize.width > 0, document.imageSize.height > 0 else { return nil }
        let scaleX = canvasSize.width / document.imageSize.width
        let scaleY = canvasSize.height / document.imageSize.height
        for operation in document.operations.reversed() {
            guard case let .text(id, value, rect, _, fontSize) = operation else { continue }
            let displayRect = CGRect(
                x: rect.minX * scaleX, y: rect.minY * scaleY,
                width: rect.width * scaleX, height: rect.height * scaleY
            )
            let lines = InlineAnnotationTextLayout.lines(
                value, in: displayRect, fontSize: fontSize * min(scaleX, scaleY)
            )
            guard lines.contains(where: { $0.visibleBounds.contains(location) }) else { continue }
            let bounds = lines.reduce(CGRect.null) { $0.union($1.visibleBounds) }
            return (id, rect, CGRect(
                x: bounds.minX / scaleX, y: bounds.minY / scaleY,
                width: bounds.width / scaleX, height: bounds.height / scaleY
            ))
        }
        return nil
    }

    /// 鼠标暂时停在其他子窗口时，画布的 cursor rect 仍应代表当前编辑状态，
    /// 不能被副工具栏的箭头或某个过期命中点污染。
    func defaultCursorContext() -> ScreenshotCursorContext {
        if isOCRMode { return .ocrText }
        if isMovingText { return .movingText }
        if document.selectedTool == .text, textEntryOrigin != nil { return .textInput }
        return document.selectedTool == .text ? .textInput : .drawing
    }

    /// 常用色写入 Document 后会由统一的配置回调持久化，不需要 View 直接访问 UserDefaults。
    func selectColor(_ color: RGBAColor) {
        guard !isProcessing else { return }
        document.setStrokeColor(color)
    }

    func selectTextFontSize(_ size: CGFloat) {
        guard !isProcessing else { return }
        textFontSize = min(max(size, 12), 72)
    }

    /// 点击画布时先提交上一段，再从新的光标位置开始输入。
    func beginTextEntry(at location: CGPoint, canvasSize: CGSize) {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        commitTextEntry()
        textEntryOrigin = CGPoint(
            x: min(max(0, location.x), canvasSize.width) * document.imageSize.width / canvasSize.width,
            y: min(max(0, location.y), canvasSize.height) * document.imageSize.height / canvasSize.height
        )
        textEntryID = UUID()
        textEntryDisplayContentSize = nil
        textEntryImageScale = min(
            document.imageSize.width / canvasSize.width,
            document.imageSize.height / canvasSize.height
        )
        textValue = ""
    }

    /// 回车、切换工具或完成截图时，把当前输入作为一次可撤销的文本标注提交。
    func commitTextEntry(matching entryID: UUID? = nil) {
        // NSTextView 从视图树移除时也会迟到地发送 textDidEndEditing；只允许原输入框
        // 提交自己的草稿，不能误提交用户刚在另一个落点创建的新输入框。
        if let entryID, textEntryID != entryID { return }
        guard let origin = textEntryOrigin else { return }
        defer {
            textEntryOrigin = nil
            textEntryID = nil
            textEntryDisplayContentSize = nil
            textValue = ""
        }

        guard !textValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // 输入界面字号以 point 计，命令保存原图像素字号；乘进入文字编辑时记录的显示倍率。
        let renderedFontSize = textFontSize * textEntryImageScale
        // 没有取得原生文本测量值时使用估算尺寸；有实际排版宽高时优先用它，以保持输入与导出的换行。
        let estimatedWidth = max(renderedFontSize * 2, CGFloat(textValue.count) * renderedFontSize)
        let renderedContentSize = textEntryDisplayContentSize.map {
            CGSize(width: $0.width * textEntryImageScale, height: $0.height * textEntryImageScale)
        }
        let rect = CGRect(
            origin: origin,
            size: CGSize(
                width: max(renderedFontSize * 2, renderedContentSize?.width ?? estimatedWidth),
                height: max(renderedFontSize * 1.6, renderedContentSize?.height ?? 0)
            )
        )
        document.commit(.text(
            id: UUID(),
            value: textValue,
            rect: rect,
            color: document.strokeStyle.color,
            fontSize: renderedFontSize
        ))
    }

    /// 把 OCR 区域转换为可交互字符序列并重置选择；识别结果是临时文本层，不进入文档撤销栈。
    func replaceOCRRegions(with regions: [OCRTextRegion]) {
        ocrCharacters = regions.enumerated().flatMap { regionIndex, region in
            let characters = region.characters.isEmpty
                ? Self.fallbackCharacters(for: region)
                : region.characters
            return characters.map {
                OCRInteractionCharacter(
                    text: $0.text,
                    regionIndex: regionIndex,
                    normalizedRect: $0.normalizedRect
                )
            }
        }
        selectedOCRCharacterRange = nil
    }

    /// 清空 OCR 交互结果与选择，返回普通编辑交互；底图像素保持原样。
    func clearOCRRegions() {
        ocrCharacters.removeAll(keepingCapacity: true)
        selectedOCRCharacterRange = nil
    }

    var selectedOCRCharacterCount: Int {
        guard let range = validSelectedOCRCharacterRange else { return 0 }
        return range.upperBound - range.lowerBound + 1
    }

    /// 把选择范围扩展到整个当前字符序列，供 Cmd+A 与复制路径复用。
    func selectAllOCRText() {
        selectedOCRCharacterRange = ocrCharacters.isEmpty
            ? nil
            : 0...(ocrCharacters.count - 1)
    }

    // 跨 OCR 区域插入换行、同一区域连续拼字；复制顺序来自前面建立的阅读顺序，未重新排序像素框。
    var selectedOCRText: String? {
        guard let range = validSelectedOCRCharacterRange else { return nil }

        var result = ""
        var previousRegionIndex: Int?
        for character in ocrCharacters[range] {
            if let previousRegionIndex,
               previousRegionIndex != character.regionIndex,
               !result.isEmpty {
                result.append("\n")
            }
            result.append(character.text)
            previousRegionIndex = character.regionIndex
        }
        return result
    }

    // 范围在当前数组边界内才允许切片；OCR 结果替换后旧下标可能已失效，不能直接下标访问。
    private var validSelectedOCRCharacterRange: ClosedRange<Int>? {
        guard let range = selectedOCRCharacterRange,
              range.lowerBound >= ocrCharacters.startIndex,
              range.upperBound < ocrCharacters.endIndex else {
            return nil
        }
        return range
    }

    /// 缺少字符级框时按文本构造估算区域，仅供交互降级；不能当成精确的字形检测结果。
    private static func fallbackCharacters(for region: OCRTextRegion) -> [OCRCharacterRegion] {
        let characters = Array(region.text).map(String.init)
        guard !characters.isEmpty else { return [] }
        let width = region.normalizedRect.width / CGFloat(characters.count)
        return characters.enumerated().map { offset, character in
            OCRCharacterRegion(
                text: character,
                normalizedRect: CGRect(
                    x: region.normalizedRect.minX + CGFloat(offset) * width,
                    y: region.normalizedRect.minY,
                    width: width,
                    height: region.normalizedRect.height
                )
            )
        }
    }

    /// 将输入钳制在画布内，再按横纵缩放比转像素。pen 保留轨迹，其他工具只需起终点。
    func updateDrag(at location: CGPoint, canvasSize: CGSize) {
        errorMessage = nil
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        let clamped = CGPoint(
            x: min(max(0, location.x), canvasSize.width),
            y: min(max(0, location.y), canvasSize.height)
        )
        // View 显示尺寸可能小于 Retina 原图。所有手势点在这里一次性换算到原图像素，
        // 后续预览和最终导出便使用同一套编辑数据。
        let point = CGPoint(
            x: clamped.x * document.imageSize.width / canvasSize.width,
            y: clamped.y * document.imageSize.height / canvasSize.height
        )

        if dragStart == nil {
            dragStart = point
            draftPoints = [point]
        } else if document.selectedTool == .pen {
            draftPoints.append(point)
        } else {
            // 前面的 if 已排除 nil，这里才强制解包；! 不是 Java/TS 的逻辑取反，值若为空会触发运行时失败。
            draftPoints = [dragStart!, point]
        }
    }

    /// 从已经冻结的截图位图中读取一个像素，不再调用 ScreenCaptureKit。
    /// Java 对照：这里是纯内存查询；鼠标坐标先映射成原图像素坐标，再交给 sampler。
    func sampleColor(at location: CGPoint, canvasSize: CGSize) {
        errorMessage = nil
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        guard let color = ScreenshotPixelSampler.color(
            in: document.original.cgImage,
            at: location,
            displayedAt: canvasSize
        ) else {
            errorMessage = AppText.text("取色失败")
            return
        }

        // 取色只更新采样结果，不覆盖各个标注工具独立保存的颜色。
        sampledColor = color
    }

    /// 松开鼠标才把临时状态转为命令；类似表单草稿在 submit 时写入共享 store。
    /// switch 必须覆盖所有工具，取色只查询颜色，不生成编辑历史。
    func commitDraft() {
        guard let start = dragStart, let end = draftPoints.last else {
            resetDraft()
            return
        }

        let rect = CGRect(
            x: start.x,
            y: start.y,
            width: end.x - start.x,
            height: end.y - start.y
        ).standardized
        let id = UUID()

        // 把当前草稿转换成一个不可变 ImageEditOperation，再交给 Document 的撤销栈。
        switch document.selectedTool {
        case .rectangle:
            guard rect.width >= 1, rect.height >= 1 else { break }
            document.commit(.shape(
                id: id,
                rect: rect,
                style: document.strokeStyle,
                isFilled: document.shapeIsFilled,
                shape: document.annotationShape
            ))
        case .arrow:
            document.commit(.arrow(
                id: id,
                start: start,
                end: end,
                style: document.strokeStyle,
                mode: document.arrowMode
            ))
        case .pen:
            document.commit(.freehand(id: id, points: draftPoints, style: document.strokeStyle))
        case .redaction:
            // 单击与拖动共用 DragGesture：位移很小时解释为点击已有色块并取消；
            // 真正拖出矩形时则使用当前标注颜色创建不透明遮挡命令。
            let movement = hypot(end.x - start.x, end.y - start.y)
            if movement < 6 {
                _ = document.removeRedaction(at: end)
            } else if rect.width >= 2, rect.height >= 2 {
                document.commit(.redaction(id: id, rect: rect, color: document.strokeStyle.color))
            }
        case .text:
            // 文本由画布上的原地输入框提交，不再把鼠标拖拽解释成固定文字矩形。
            break
        case .step:
            document.commit(.step(
                id: id,
                number: document.nextStepNumber,
                center: end,
                diameter: max(44, document.strokeStyle.width * 11),
                color: document.strokeStyle.color
            ))
        case .colorPicker:
            // 取色在 DragGesture.onEnded 中完成，不生成可撤销的图片编辑命令。
            break
        }
        resetDraft()
    }

    /// 丢弃尚未提交的鼠标草稿；因为没有进入文档，不需要增加一条撤销命令。
    func cancelDraft() {
        resetDraft()
    }

    /// 保留数组容量以复用拖动缓冲，释放的是元素引用；关闭会话后整个数组再随对象释放。
    private func resetDraft() {
        dragStart = nil
        draftPoints.removeAll(keepingCapacity: true)
    }

}
