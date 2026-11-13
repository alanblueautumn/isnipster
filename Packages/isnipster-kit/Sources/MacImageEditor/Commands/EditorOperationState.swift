import Foundation
import MacShared

/// 同一会话只有一个任务状态，画布、工具栏和任务收尾共同读取它。
enum EditorProcessingKind: Equatable { case ocr, redaction, translation }
enum EditorExportTarget: Equatable { case imageClipboard, fileClipboard, pin }
enum EditorOperationState: Equatable {
    case idle
    case processing(UUID, EditorProcessingKind)
    case exporting(UUID, EditorExportTarget)
    case closed

    var requestID: UUID? {
        switch self {
        case let .processing(id, _), let .exporting(id, _): id
        case .idle, .closed: nil
        }
    }

    var allowsCanvasEditing: Bool {
        switch self {
        case .idle, .processing(_, .redaction): true
        default: false
        }
    }

    var progressMessage: String? {
        switch self {
        case .idle, .closed: nil
        case .processing(_, .ocr): AppText.text("正在识别文字…")
        case .processing(_, .redaction): AppText.text("正在智能打码…")
        case .processing(_, .translation): AppText.text("正在翻译图片…")
        case .exporting(_, .pin): AppText.text("正在生成贴图…")
        case .exporting: AppText.text("正在复制图片…")
        }
    }
}
