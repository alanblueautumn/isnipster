import MacShared
import MacPreferences
import AppKit

/// 快照中的窗口和响应者使用弱引用，粘贴等待期间不延长原窗口生命周期。
@MainActor
struct ClipboardFocusTarget {
    let application: NSRunningApplication?
    weak var window: NSWindow? = nil
    weak var responder: NSResponder? = nil

    func restore() {
        if let window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            if let responder { window.makeFirstResponder(responder) }
        } else {
            handOffActivation(to: application)
        }
    }

    func pasteLocally() {
        guard let window, window.isVisible else { return }
        window.makeKeyAndOrderFront(nil)
        if let text = responder as? NSTextView, text.window === window,
           text.isEditable, window.makeFirstResponder(text) {
            text.paste(nil)
        }
    }
}

@MainActor
final class ClipboardFocusCoordinator {
    private var application: NSRunningApplication?
    private weak var window: NSWindow?
    private weak var responder: NSResponder?
    private var lastExternalApplication: NSRunningApplication?

    init() {
        if let current = NSWorkspace.shared.frontmostApplication {
            recordActivation(current)
        }
    }

    var target: ClipboardFocusTarget {
        ClipboardFocusTarget(application: application, window: window, responder: responder)
    }

    func recordActivation(_ application: NSRunningApplication) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApplication = application
    }

    func remember(excluding panel: NSWindow?) {
        clearLocal()
        if NSApp.isActive, let window = NSApp.keyWindow, window !== panel, window.isVisible {
            self.window = window
            responder = window.firstResponder
            application = nil
        } else if let current = NSWorkspace.shared.frontmostApplication,
                  current.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            application = current
            recordActivation(current)
        } else {
            application = lastExternalApplication.flatMap { $0.isTerminated ? nil : $0 }
        }
    }

    func takeTarget() -> ClipboardFocusTarget {
        let saved = target
        clearApplication()
        clearLocal()
        return saved
    }

    func clearApplication() { application = nil }
    func clearLocal() { window = nil; responder = nil }
}
