import ClipboardFeature
import Foundation
import ImageEditorFeature
import MacShared
import iSnipsterCore

enum EditorExportResult: Sendable {
    case copied
    case pin(RasterImage)
}

/// 任务由编辑会话管理，本服务只渲染快照并输出；不持有窗口或启动独立 Task。
@MainActor
final class EditorExportService {
    private let renderer: any ImageRendering
    private let encoder = RasterImageEncoder()
    private let clipboardWriter: any ClipboardWriting

    init(renderer: any ImageRendering, clipboardWriter: any ClipboardWriting) {
        self.renderer = renderer
        self.clipboardWriter = clipboardWriter
    }

    func export(_ snapshot: ImageDocumentSnapshot, to target: EditorExportTarget) async throws -> EditorExportResult {
        try Task.checkCancellation()
        let image = try await renderer.render(document: snapshot)
        try Task.checkCancellation()
        if target == .pin { return .pin(image) }
        let data = try await encoder.pngData(from: image)
        try Task.checkCancellation()
        let content = ClipboardContent.imagePNG(data, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight)
        switch target {
        case .imageClipboard:
            try await clipboardWriter.writeImageAndRecord(content)
        case .fileClipboard:
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            try await clipboardWriter.writePNGFile(data,
                suggestedName: "iSnipster-\(formatter.string(from: .now)).png", recording: content)
        case .pin: break
        }
        return .copied
    }
}
