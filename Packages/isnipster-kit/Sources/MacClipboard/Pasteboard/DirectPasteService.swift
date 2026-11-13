import MacShared
import MacPreferences
// 阅读路线
// 切回目标应用 → 等待前台切换 → 再确认权限与目标 → 投递 Cmd+V 按下/抬起事件。
// Task.sleep 挂起任务而不占住主线程；每次 await 后外部焦点都可能已变化。
// 官方参考（CGEvent 合成事件）：https://developer.apple.com/documentation/coregraphics/cgevent

import AppKit
import iSnipsterCore

/// 请求将前台控制权交回粘贴目标；目标应用决定如何恢复自己的窗口和输入焦点。
/// 激活请求不提供“原输入框已就绪”的保证，发送按键前还需等待并重新确认前台进程。
@MainActor
func handOffActivation(to application: NSRunningApplication?) {
    guard let application, !application.isTerminated else { return }
    // NSApp 是当前进程唯一的 NSApplication 单例；yieldActivation 让菜单栏应用交还前台控制权。
    NSApp.yieldActivation(to: application)
    application.activate(options: [])
}

/// 有事件发送权限时完成 Paste 式的“一次选择、直接回填”；没有权限时内容仍已回写
/// 到系统剪贴板，用户可以手动 Command+V，或主动选择开启自动粘贴授权。
@MainActor
final class DirectPasteService {
    func sendPasteShortcut(to application: NSRunningApplication?, isCurrent: @escaping @MainActor () -> Bool) async throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard let application, !application.isTerminated else {
            throw AppFailure.unavailable(AppText.text("目标应用已关闭，内容已复制，可手动粘贴。"))
        }

        try requireAccess()
        handOffActivation(to: application)

        // 等待目标应用真正成为前台；每轮都检查取消，避免旧粘贴请求在用户已切换目标后迟到触发。
        // NSRunningApplication.activate 是异步的。轮询 frontmostApplication 只是在等前台切换完成，
        // 不是忙等：每轮 Task.sleep 都会挂起协作任务、不阻塞主线程。
        for _ in 0..<40 {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            guard !application.isTerminated else {
                throw AppFailure.unavailable(AppText.text("目标应用已关闭，内容已复制，可手动粘贴。"))
            }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                break
            }
            // sleep 让当前 Task 挂起，其他任务仍可运行；try 说明等待期间取消可能抛出 CancellationError。
            try await Task.sleep(for: .milliseconds(25))
        }

        // 应用成为前台后，内部 TextField 的 First Responder 还可能晚一小段时间建立，因此再让出 80ms。
        try await Task.sleep(for: .milliseconds(80))
        try Task.checkCancellation()
        guard !application.isTerminated,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
            throw AppFailure.operationFailed(AppText.text("未能切回目标应用，内容已复制，可手动粘贴。"))
        }
        guard isCurrent() else { throw CancellationError() }
        try requireAccess()
        try postCommandV(to: application.processIdentifier)
    }

    private func requireAccess() throws {
        guard AppPermission.directPaste.isGranted else {
            throw AppFailure.permissionDenied(AppPermission.directPaste.denialMessage)
        }
    }

    private func postCommandV(to processIdentifier: pid_t) throws {
        // CGEvent 是 Quartz 层的合成输入事件。虚拟键码 9 表示物理 V 键，不等于字符 "v"；
        // 键盘布局只影响它最终输入什么字符，Command 修饰键使目标应用把它解释为粘贴命令。
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 9,
                keyDown: false
              ) else {
            throw AppFailure.operationFailed(AppText.text("无法发送粘贴快捷键，内容已复制，可手动粘贴。"))
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        // postToPid 只表示事件已发送给目标进程，没有“文本确实插入”的回执；这正是失败时仍保留系统剪贴板的原因。
        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }
}
