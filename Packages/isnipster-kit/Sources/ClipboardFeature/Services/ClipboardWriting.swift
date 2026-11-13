import Foundation

/// 功能输出端口；不暴露历史查询、删除、分类或监控生命周期。
@MainActor
public protocol ClipboardWriting: AnyObject {
    func writeWithoutRecording(_ content: ClipboardContent) throws
    func writeAndRecord(_ content: ClipboardContent) throws
    func writeImageAndRecord(_ content: ClipboardContent) async throws
    func writePNGFile(_ data: Data, suggestedName: String, recording content: ClipboardContent?) async throws
}
