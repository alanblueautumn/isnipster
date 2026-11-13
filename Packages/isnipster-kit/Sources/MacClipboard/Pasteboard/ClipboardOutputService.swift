import MacShared
import MacPreferences
import ClipboardFeature
import Foundation

/// 所有应用内输出共享计数同步，防止轮询再次采集应用自己写入的内容。
@MainActor
public final class ClipboardOutputService: ClipboardWriting {
    private let controller: ClipboardController
    private let client: any PasteboardClient
    private let fileStore = ClipboardTemporaryFileStore()
    private var outputID = UUID()
    private var publishedFileURL: URL?

    public init(controller: ClipboardController, client: any PasteboardClient) {
        self.controller = controller
        self.client = client
    }

    public func writeWithoutRecording(_ content: ClipboardContent) throws {
        outputID = UUID()
        try controller.writeWithoutRecording(content)
    }

    public func writeAndRecord(_ content: ClipboardContent) throws {
        outputID = UUID()
        try controller.writeAndRecord(content)
    }

    public func writeImageAndRecord(_ content: ClipboardContent) async throws {
        outputID = UUID()
        try await controller.writeImageAndRecord(content)
    }

    public func writePNGFile(_ data: Data, suggestedName: String, recording content: ClipboardContent?) async throws {
        try Task.checkCancellation()
        let id = UUID()
        outputID = id
        let previousChangeCount = client.changeCount
        let url = try await fileStore.preparePNG(data, suggestedName: suggestedName, protecting: publishedFileURL)
        do {
            try Task.checkCancellation()
            guard outputID == id, client.changeCount == previousChangeCount else { throw CancellationError() }
            // 校验、发布和 changeCount 同步在同一个 MainActor 调用内完成。
            try controller.writeWithoutRecording(.files([url]))
            publishedFileURL = url
            if let content { controller.recordApplicationGenerated(content) }
        } catch {
            await fileStore.discard(url)
            throw error
        }
    }
}
