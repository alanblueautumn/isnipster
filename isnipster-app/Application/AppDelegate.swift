// 阅读路线
// 这里接收应用启动、唤醒、退出回调，并持有状态栏与权限窗口控制器。
// SwiftUI 管内容，AppKit 管桌面窗口与事件；NSObject/#selector/@objc 是接入 Objective-C 回调的桥梁。
// 官方参考（应用生命周期代理）：https://developer.apple.com/documentation/appkit/nsapplicationdelegate

import AppKit
import MacPlatform

// 这里类似应用启动/退出钩子：启动时创建常驻服务，退出时停止监听。
// macOS 用 NSApplicationDelegate；iOS 对应 UIApplicationDelegate，SwiftUI 的桥接属性也不同。

/// AppKit 生命周期代理。
///
/// NSObject 提供 Objective-C 基础对象行为；本类继承它并实现 NSApplicationDelegate，
/// 类似 Java 的框架回调对象，额外通过 Objective-C 运行时接收 selector 消息。
/// `@MainActor` 等价于声明整个类只能在 UI 主线程隔离域中访问。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// `let` 类似 Java 的 final 引用：root 不能重新赋值，但 root 内部对象仍可变化。
    // class 由 ARC 引用计数管理，强引用使实例存活；与 Java 的追踪式 GC 不同，强引用环不会自动消失。
    let root = CompositionRoot()
    private var statusBarController: StatusBarController?
    private var onboardingWindowController: OnboardingWindowController?
    private var permissionListObserver: NSObjectProtocol?

    /// 系统完成 NSApplication 初始化后调用，可类比 Spring 的 ApplicationReadyEvent。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSApplicationDelegate 的生命周期回调由 AppKit 调用；不要自己调用它，
        // 它相当于 Spring 容器完成初始化后通知应用“现在可以创建窗口和注册系统服务”。
        AppUILanguage.prepareForNextLaunch(AppUILanguage.selected)
        // 菜单栏工具不长期占用 Dock；编辑器打开时仍可成为前台应用。
        // NSApp 是当前进程唯一的应用对象。`.accessory` 让本应用显示菜单栏图标、但默认不显示 Dock 图标和 Cmd-Tab 项。
        NSApp.setActivationPolicy(.accessory)
        statusBarController = StatusBarController(model: root.appModel)

        root.clipboardController.start()
        // NSWorkspace 是 macOS 工作区服务；它自己的 notificationCenter 发出睡眠、唤醒、应用启动等系统事件。
        // selector 写法来自 Objective-C：运行时按方法名调用带一个 Notification 参数的方法。
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(workspaceDidWake(_:)),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        // 剪贴板窗口及其文本输入服务在用户首次打开时创建。
        root.appModel.registerGlobalHotKeys()
        // 闭包式观察者返回 token。必须保存在属性并在 terminate 时 remove，否则观察者会比业务对象活得更久。
        permissionListObserver = NotificationCenter.default.addObserver(
            forName: .iSnipsterShouldShowPermissionList,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let permission = notification.object as? AppPermission else { return }
            Task { @MainActor in
                self?.showPermissionList(for: permission)
            }
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        return true
    }

    private func showPermissionList(for permission: AppPermission) {
        // NSWindowController 是 AppKit 的“窗口所有者”：持有 NSWindow，同时承担显示、关闭和 delegate 回调协调。
        let status = AppPermissionStatus.current(for: permission)
        if let onboardingWindowController {
            onboardingWindowController.show(status: status)
            return
        }

        let controller = OnboardingWindowController(
            status: status,
            onComplete: { [weak self] in
                self?.closeOnboarding()
            },
            onDismiss: { [weak self] in
                self?.onboardingDidClose()
            }
        )
        onboardingWindowController = controller
        controller.show(status: status)
    }

    private func closeOnboarding() {
        onboardingWindowController?.close()
    }

    private func onboardingDidClose() {
        onboardingWindowController = nil
        NSApp.setActivationPolicy(.accessory)
    }

    @objc private func workspaceDidWake(_ notification: Notification) {
        root.clipboardController.scheduleMaintenance()
    }

    /// 退出前只停止轮询。内存会随进程释放，持久化历史必须保留到下次启动。
    func applicationWillTerminate(_ notification: Notification) {
        if let permissionListObserver {
            NotificationCenter.default.removeObserver(permissionListObserver)
        }
        NSWorkspace.shared.notificationCenter.removeObserver(
            self, name: NSWorkspace.didWakeNotification, object: nil
        )
        root.clipboardController.stop()
    }
}
