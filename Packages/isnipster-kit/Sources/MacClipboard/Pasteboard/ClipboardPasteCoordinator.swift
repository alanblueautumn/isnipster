import AppKit
import ClipboardFeature
import MacPreferences
import MacShared
import iSnipsterCore

enum ClipboardPastePermissionResponse { case enableAccess, copyOnly, dismiss }

@MainActor
protocol ClipboardPastePresentation: AnyObject {
    func dismissForPaste(completion: @escaping @MainActor () -> Void)
    func showPastePermission(destinationName: String?, response: @escaping @MainActor (ClipboardPastePermissionResponse) -> Void)
    func closePastePermissionPrompt()
    func resumeAfterPastePrompt()
    func pasteFailed(_ error: Error)
}

/// 一次粘贴的内容、目标和任务归属。动画与授权窗口仅通过回调参与，不拥有业务 Task。
@MainActor
final class ClipboardPasteCoordinator {
    private struct Request {
        let id: UUID
        let target: ClipboardFocusTarget
        var changeCount: Int?
    }
    weak var presentation: (any ClipboardPastePresentation)?
    private let controller: ClipboardController
    private let writer: any ClipboardWriting
    private let client: any PasteboardClient
    private let directPaste = DirectPasteService()
    private var request: Request?
    private var task: Task<Void, Never>?

    init(controller: ClipboardController, writer: any ClipboardWriting, client: any PasteboardClient) {
        self.controller = controller
        self.writer = writer
        self.client = client
    }

    func cancel() {
        request = nil
        task?.cancel()
        task = nil
        presentation?.closePastePermissionPrompt()
    }

    func copy(_ entry: ClipboardEntry, asPlainText: Bool) {
        begin(entry, asPlainText: asPlainText, target: nil)
    }

    func paste(_ entry: ClipboardEntry, asPlainText: Bool, target: ClipboardFocusTarget) {
        begin(entry, asPlainText: asPlainText, target: target)
    }

    private func begin(_ entry: ClipboardEntry, asPlainText: Bool, target: ClipboardFocusTarget?) {
        cancel()
        if case let .files(urls) = entry.content,
           urls.contains(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
            controller.scheduleMaintenance()
            presentation?.pasteFailed(AppFailure.unavailable(AppText.text("文件暂时无法访问，请确认文件位置和访问权限后重试")))
            return
        }
        let id = UUID()
        request = Request(id: id, target: target ?? ClipboardFocusTarget(application: nil), changeCount: nil)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                if target?.application?.bundleIdentifier == "com.apple.finder",
                   case let .imagePNG(data, _, _) = entry.content {
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyyMMdd-HHmmss"
                    try await writer.writePNGFile(data,
                        suggestedName: "iSnipster-\(formatter.string(from: .now)).png", recording: nil)
                    controller.markUsed(entry)
                } else {
                    try await controller.activate(entry, asPlainText: asPlainText)
                }
                try Task.checkCancellation()
                guard request?.id == id else { return }
                request?.changeCount = client.changeCount
                task = nil
                if target == nil { finish(id); return }
                continuePaste(id)
            } catch {
                handle(error, id: id)
            }
        }
    }

    private func isCurrent(_ id: UUID) -> Bool {
        guard let request, request.id == id else { return false }
        return request.changeCount == nil || request.changeCount == client.changeCount
    }

    private func continuePaste(_ id: UUID) {
        guard isCurrent(id), let target = request?.target else { finish(id); return }
        if let application = target.application, !application.isTerminated,
           !AppPermission.directPaste.isGranted {
            requestPermission(id)
            return
        }
        presentation?.dismissForPaste { [weak self] in
            guard let self, isCurrent(id) else { self?.finish(id); return }
            if target.window != nil {
                target.pasteLocally()
                finish(id)
            } else if let application = target.application {
                sendPaste(to: application, id: id)
            } else {
                finish(id)
            }
        }
    }

    private func sendPaste(to application: NSRunningApplication, id: UUID) {
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await directPaste.sendPasteShortcut(to: application, isCurrent: { [weak self] in
                    self?.isCurrent(id) == true
                })
                finish(id)
            } catch {
                guard isCurrent(id) else { finish(id); return }
                if let failure = error as? AppFailure, case .permissionDenied = failure {
                    task = nil
                    requestPermission(id)
                } else {
                    handle(error, id: id)
                }
            }
        }
    }

    private func requestPermission(_ id: UUID) {
        guard isCurrent(id), let target = request?.target else { finish(id); return }
        if AppPreferences.Clipboard.suppressesDirectPastePermissionPrompt.read() {
            dismissAndRestore(target, id: id)
            return
        }
        presentation?.showPastePermission(destinationName: target.application?.localizedName) { [weak self] response in
            guard let self, isCurrent(id) else {
                self?.finish(id)
                self?.presentation?.resumeAfterPastePrompt()
                return
            }
            switch response {
            case .enableAccess:
                presentation?.dismissForPaste { [weak self] in
                    guard let self, isCurrent(id) else { self?.finish(id); return }
                    finish(id)
                    // 用户授权后重新选择记录，旧请求不会自动补发。
                    AppPermission.directPaste.requestAccess()
                }
            case .copyOnly:
                dismissAndRestore(target, id: id)
            case .dismiss:
                finish(id)
                presentation?.resumeAfterPastePrompt()
            }
        }
    }

    private func dismissAndRestore(_ target: ClipboardFocusTarget, id: UUID) {
        presentation?.dismissForPaste { [weak self] in
            guard let self, isCurrent(id) else { self?.finish(id); return }
            finish(id)
            target.restore()
        }
    }

    private func handle(_ error: Error, id: UUID) {
        guard request?.id == id else { return }
        let cancelled = Task.isCancelled || TaskCancellation.isCancellation(error)
        finish(id)
        guard !cancelled else { return }
        AppDiagnostics.failure(error, stage: "clipboard.paste", requestID: id)
        presentation?.pasteFailed(error)
    }

    private func finish(_ id: UUID) {
        guard request?.id == id else { return }
        request = nil
        task = nil
    }
}
