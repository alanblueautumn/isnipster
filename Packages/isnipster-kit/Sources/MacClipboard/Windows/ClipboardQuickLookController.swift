import MacShared
import MacPreferences
import AppKit
import ClipboardFeature
import Quartz
import iSnipsterCore

/// 在独立面板中嵌入系统 Quick Look，不依赖共享预览面板的 responder chain 控制权。
@MainActor
final class ClipboardQuickLookController: NSObject, NSWindowDelegate {
    private var items: [NSURL] = []
    private var temporaryDirectory: URL?
    private var accessedFileURLs: [URL] = []
    private weak var sourceWindow: NSWindow?
    private var previewPanel: ClipboardPreviewPanel?
    private var previewView: QLPreviewView?
    private var itemNavigation: NSSegmentedControl?
    private var itemPositionLabel: NSTextField?
    private var currentItemIndex = 0
    private(set) var previewedEntryID: UUID?

    var isVisible: Bool { previewPanel?.isVisible == true }

    func contains(_ point: NSPoint) -> Bool {
        guard let previewPanel, previewPanel.isVisible else { return false }
        return previewPanel.frame.contains(point)
    }

    func toggle(_ entry: ClipboardEntry, from window: NSWindow) throws {
        if isVisible, previewedEntryID == entry.id {
            close(restoreFocus: true)
            return
        }
        close()
        sourceWindow = window

        do {
            switch entry.content {
            case let .files(urls):
                guard !urls.isEmpty else {
                    throw AppFailure.invalidData(AppText.text("剪贴板文件引用无效"))
                }
                for url in urls {
                    if url.startAccessingSecurityScopedResource() {
                        accessedFileURLs.append(url)
                    }
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw AppFailure.unavailable(AppText.text("文件暂时无法访问，请确认文件位置和访问权限后重试"))
                    }
                }
                items = urls.map { $0 as NSURL }
            case let .imagePNG(data, _, _):
                items = [try temporaryItem(data: data, fileExtension: "png")]
            case let .text(value), let .color(value):
                items = [try temporaryItem(data: Data(value.utf8), fileExtension: "txt")]
            case let .url(url):
                // 链接预览展示完整地址，不让系统预览器加载网页。
                items = [try temporaryItem(data: Data(url.absoluteString.utf8), fileExtension: "txt")]
            }
            previewedEntryID = entry.id
            let panel = try makePreviewPanel(from: window)
            previewPanel = panel
            currentItemIndex = 0
            updatePreviewItem()
            // 非激活面板直接接收键盘，不激活应用或让玻璃效果辅助窗口参与焦点切换。
            panel.makeKeyAndOrderFront(nil)
        } catch {
            close()
            throw error
        }
    }

    func close(restoreFocus: Bool = false) {
        let window = sourceWindow
        let panel = previewPanel
        panel?.delegate = nil
        panel?.onDismiss = nil
        panel?.onMoveItem = nil
        // 关闭后 QLPreviewView 不可再复用；下次预览创建新实例。
        previewView?.close()
        previewView = nil
        panel?.close()
        previewPanel = nil
        itemNavigation = nil
        itemPositionLabel = nil
        releaseContent()
        if restoreFocus, let window, window.isVisible {
            window.makeKey()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let panel = notification.object as? NSWindow, previewPanel === panel else { return }
        // 用户点关闭按钮时，窗口已在关闭流程中，只清理内容并恢复来源窗口。
        panel.delegate = nil
        previewPanel = nil
        close(restoreFocus: true)
    }

    private func makePreviewPanel(from window: NSWindow) throws -> ClipboardPreviewPanel {
        let available = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        let size = NSSize(width: min(860, available.width * 0.8), height: min(620, available.height * 0.7))
        let panel = ClipboardPreviewPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        guard let preview = QLPreviewView(frame: .zero, style: .normal) else {
            throw AppFailure.unavailable(AppText.text("无法创建系统预览视图"))
        }
        // 统一由 close() 清理，保证临时文件和访问权限在预览视图释放之后再回收。
        preview.shouldCloseWithWindow = false
        preview.autostarts = false
        previewView = preview

        let content = NSView(frame: NSRect(origin: .zero, size: size))
        panel.contentView = content
        preview.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(preview)
        var previewTop = content.topAnchor
        if items.count > 1 {
            let navigation = NSSegmentedControl(
                labels: ["‹", "›"],
                trackingMode: .momentary,
                target: self,
                action: #selector(changePreviewItem(_:))
            )
            let position = NSTextField(labelWithString: "")
            position.textColor = .secondaryLabelColor
            let header = NSStackView(views: [navigation, position])
            header.orientation = .horizontal
            header.spacing = 12
            header.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(header)
            NSLayoutConstraint.activate([
                header.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
                header.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                header.heightAnchor.constraint(equalToConstant: 28)
            ])
            previewTop = header.bottomAnchor
            itemNavigation = navigation
            itemPositionLabel = position
        }
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: previewTop),
            preview.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            preview.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = NSWindow.Level(rawValue: window.level.rawValue + 1)
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.minSize = NSSize(width: min(400, size.width), height: min(280, size.height))
        panel.setFrameOrigin(NSPoint(
            x: available.midX - panel.frame.width / 2,
            y: max(available.minY, min(window.frame.maxY + 16, available.maxY - panel.frame.height))
        ))
        panel.delegate = self
        panel.onDismiss = { [weak self] in self?.close(restoreFocus: true) }
        panel.onMoveItem = { [weak self] offset in self?.movePreviewItem(by: offset) }
        return panel
    }

    @objc
    private func changePreviewItem(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0 else { return }
        movePreviewItem(by: sender.selectedSegment == 0 ? -1 : 1)
    }

    private func movePreviewItem(by offset: Int) {
        let index = currentItemIndex + offset
        guard items.indices.contains(index) else { return }
        currentItemIndex = index
        updatePreviewItem()
    }

    private func updatePreviewItem() {
        guard items.indices.contains(currentItemIndex) else { return }
        let item = items[currentItemIndex]
        previewView?.previewItem = item
        previewPanel?.title = (item as URL).lastPathComponent
        itemPositionLabel?.stringValue = "\(currentItemIndex + 1) / \(items.count)"
        itemNavigation?.setEnabled(currentItemIndex > 0, forSegment: 0)
        itemNavigation?.setEnabled(currentItemIndex + 1 < items.count, forSegment: 1)
        previewPanel?.hasMultipleItems = items.count > 1
    }

    private func temporaryItem(data: Data, fileExtension: String) throws -> NSURL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("isnipster-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectory = directory
        let file = directory.appendingPathComponent("iSnipster.\(fileExtension)")
        try data.write(to: file, options: .atomic)
        return file as NSURL
    }

    private func releaseContent() {
        items = []
        previewedEntryID = nil
        sourceWindow = nil
        accessedFileURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        accessedFileURLs = []
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }
}

/// 明确接收预览快捷键的非激活窗口，避免把 NSEvent 跨隔离域传递。
@MainActor
private final class ClipboardPreviewPanel: NSPanel {
    var onDismiss: (@MainActor () -> Void)?
    var onMoveItem: (@MainActor (Int) -> Void)?
    var hasMultipleItems = false

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            switch event.keyCode {
            case 49, 53:
                if !event.isARepeat { onDismiss?() }
                return
            case 123 where hasMultipleItems:
                onMoveItem?(-1)
                return
            case 124 where hasMultipleItems:
                onMoveItem?(1)
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }
}
