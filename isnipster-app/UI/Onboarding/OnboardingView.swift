// 阅读路线
// 权限事件 → AppDelegate 建窗口 → View 请求授权 → 应用重新激活时刷新状态。
// 请求返回与用户完成授权不是同一时刻；权限结果来自系统预检，不能仅靠页面上的 Bool 推断。
// 官方参考（NSWindowController 窗口生命周期）：https://developer.apple.com/documentation/appkit/nswindowcontroller

// AppKit 管窗口、原生弹窗和应用激活；SwiftUI 声明权限页内容；Observation 让普通类的属性变化可驱动 View 刷新。
import AppKit
import CoreGraphics
import MacPlatform
import Observation
import SwiftUI

extension Notification.Name {
    /// Notification.Name 只是字符串事件名的类型安全包装；项目用它让任意模块请求 AppDelegate 展示权限窗口，
    /// 类似浏览器 EventTarget 的自定义事件，而不是 HTTP 请求。
    static let iSnipsterShouldShowPermissionList = Notification.Name(
        "iSnipsterShouldShowPermissionList"
    )
}

@MainActor
@Observable
private final class PermissionListState {
    /// `@Observable` 由 Observation 框架生成属性读取追踪；SwiftUI 读到某属性后，写入它会只刷新依赖该属性的 View。
    var status: AppPermissionStatus
    var isVisible = false

    init(status: AppPermissionStatus) {
        self.status = status
    }
}

@MainActor
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private static let windowContentSize = NSSize(width: 620, height: 430)
    private let onDismiss: () -> Void
    private let permissionState: PermissionListState
    private var isPresenting = false

    init(
        status: AppPermissionStatus,
        onComplete: @escaping () -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        let permissionState = PermissionListState(status: status)
        self.permissionState = permissionState
        let rootView = PermissionContentView(permissionState: permissionState, onComplete: onComplete)
        // NSHostingController 是 SwiftUI 与 AppKit 的桥：把声明式 View 安装进传统 NSWindow 的 contentViewController。
        let hostingController = NSHostingController(rootView: rootView)
        // NSWindow 管理桌面窗口、焦点、层级和 Space；SwiftUI 只负责其中的内容树。
        let window = NSWindow(
            contentRect: Self.centeredContentRect(size: Self.windowContentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        // contentViewController 是 AppKit 窗口内容的标准所有者。保留 controller 后，SwiftUI View 的状态和生命周期随窗口走。
        window.contentViewController = hostingController
        window.title = AppText.text("iSnipster 权限设置")
        // 下面这些都是窗口“外壳”属性；SwiftUI 的 VStack/HStack 无法设置标题栏、层级或 Space 行为。
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        // 关闭时是否自动释放是 AppKit 的窗口生命周期选项；控制器若要复用窗口，会显式保留并自行管理引用。
        window.isReleasedWhenClosed = false
        // 弹出时由 show() 主动置顶；使用普通窗口层级，用户切换到其他应用后
        // 允许授权列表被对应窗口覆盖，不长期悬浮在桌面最上层。
        window.level = .normal
        // 指定系统对窗口显示/隐藏采用的动画行为；与内容图层 CABasicAnimation 是不同层面的动画。
        window.animationBehavior = .none
        // collectionBehavior 指窗口如何跟随 macOS Space / 全屏应用：这里允许出现在所有 Space，并可附着在全屏空间。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        Self.center(window)
        window.delegate = self
    }

    @available(*, unavailable)
    // NSCoder 初始化用于 Storyboard/XIB 解档；本类型仅支持代码创建，下面明确拒绝解档构造路径。
    required init?(coder: NSCoder) {
        return nil
    }

    func show(status: AppPermissionStatus) {
        permissionState.status = status
        guard let window, !isPresenting else { return }
        permissionState.isVisible = true
        isPresenting = true
        let isFirstPresentation = !window.isVisible

        // 首次引导临时作为普通前台应用显示，确保系统从当前应用切换到引导窗口。
        // 授权引导需要像普通应用一样获得焦点和 Dock 存在感，故暂时从 accessory 切成 regular；关闭后 AppDelegate 会切回 accessory。
        NSApp.setActivationPolicy(.regular)
        if isFirstPresentation {
            window.alphaValue = 0
        }
        Self.center(window)
        // 向系统请求应用激活；是否获准以及何时完成由系统决定，不能把调用返回当作已经取得焦点。
        NSApp.activate(ignoringOtherApps: true)
        Self.center(window)
        // key window 接收键盘事件；orderFront 只调整可见层级。二者分开正是 AppKit 常见的窗口控制方式。
        window.makeKeyAndOrderFront(nil)
        // 把窗口放到前面显示，不等于激活整个应用或把某个输入控件设为 first responder。
        window.orderFrontRegardless()

        // 前台激活是异步请求；把最终定位和显现排到主队列稍后处理，减少与当前点击事件互相影响。
        // DispatchQueue.main.async 不是 JS 微任务，不能依赖二者具有相同的调度顺序。
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            NSApp.activate(ignoringOtherApps: true)
            Self.center(window)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            window.alphaValue = 1
            self.isPresenting = false
        }
    }

    func windowWillClose(_ notification: Notification) {
        // NSWindowDelegate 回调由窗口关闭过程触发；此处只同步状态和通知所有者，不再重复调用 close。
        permissionState.isVisible = false
        onDismiss()
    }

    private static var desktopScreen: NSScreen? {
        // NSScreen.screens 返回当前显示器列表。NSScreenNumber 是 AppKit 字典里的 NSNumber，
        // 转成 CGDirectDisplayID 后才能与 CoreGraphics 的 CGMainDisplayID 比较。
        NSScreen.screens.first(where: { screen in
            guard let screenNumber = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(screenNumber.uint32Value) == CGMainDisplayID()
        }) ?? NSScreen.screens.first
    }

    private static func centeredContentRect(size: NSSize) -> NSRect {
        let screenFrame = desktopScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        return NSRect(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
    }

    private static func center(_ window: NSWindow?) {
        guard let window, let screen = desktopScreen else { return }
        window.contentView?.layoutSubtreeIfNeeded()

        let screenFrame = screen.visibleFrame
        let windowSize = window.frame.size
        let centeredFrame = NSRect(
            x: screenFrame.midX - windowSize.width / 2,
            y: screenFrame.midY - windowSize.height / 2,
            width: windowSize.width,
            height: windowSize.height
        )
        window.setFrame(centeredFrame, display: false, animate: false)
    }
}

private struct PermissionContentView: View {
    let permissionState: PermissionListState
    let onComplete: () -> Void

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // body 是纯声明：状态变化时 SwiftUI 重算这个描述，并由框架比较差异后更新原生 View；
        // 不能在 body 里直接弹窗、写 UserDefaults 或发网络请求，否则重渲染会重复触发副作用。
        OnboardingView(permissionState: permissionState, onComplete: onComplete)
            // 显式指定视图身份；值变化可让 SwiftUI 重建该子树的局部状态，不只是换一个显示标签。
            .id(permissionState.status.permission)
    }
}

private struct OnboardingView: View {
    let permissionState: PermissionListState
    let onComplete: () -> Void

    // @State 的存储由 SwiftUI 持有，View struct 每次重建仍保留它；只用于此视图的短暂交互，非应用级状态。
    @State private var didPresentScreenCaptureRestartPrompt = false
    @State private var isAwaitingAuthorization = false

    private var permission: AppPermission { permissionState.status.permission }
    private var isGranted: Bool { permissionState.status.isGranted }

    var body: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                    .frame(width: 72, height: 72)
                    // 控制辅助功能树中的可见性，不改变屏幕显示；装饰图标可隐藏，动作语义由外层按钮提供。
                    .accessibilityHidden(true)

                Text(AppText.text(permission == .screenCapture ? "截图权限" : "粘贴到当前光标"))
                    .font(.system(size: 25, weight: .bold))

                Text(permissionDescription)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
            .padding(.horizontal, 30)
            .padding(.top, 38)
            .padding(.bottom, 24)

            HStack(spacing: 14) {
                Image(systemName: permission == .screenCapture
                    ? "rectangle.dashed.badge.record" : "cursorarrow.click.2")
                    .font(.system(size: 22))
                    .foregroundStyle(.blue)

                Text(AppText.text(permission == .screenCapture ? "截图权限" : "粘贴到当前光标"))
                    .font(.system(size: 14, weight: .semibold))

                Spacer()

                if isGranted {
                    Label(AppText.text("已允许"), systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.green)
                } else {
                    if permission == .directPaste {
                        Button(AppText.text(.openSystemSettings)) {
                            isAwaitingAuthorization = true
                            permission.openSystemSettings()
                        }
                        .buttonStyle(.link)
                    }
                    Button(AppText.text("授权")) {
                        requestAccess()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
            // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .padding(.horizontal, 30)

            Spacer(minLength: 18)
            Divider()

            HStack {
                Spacer()
                Button(AppText.text(isGranted ? "完成设置" : "稍后")) {
                    onComplete()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 30)
            .frame(height: 76)
        }
        .frame(width: 620, height: 430)
        .background(.ultraThinMaterial)
        // onAppear 是 View 首次进入界面树时的生命周期钩子，接近 Vue onMounted；刷新的是系统 TCC 的实时状态。
        .onAppear {
            refreshPermissionState()
        }
        // 用户从系统设置返回后，应用重新激活。Combine publisher 把通知中心转换成 SwiftUI 可订阅的数据流。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            guard permissionState.isVisible else { return }
            refreshPermissionState()
            if isAwaitingAuthorization && isGranted {
                authorizationDidComplete()
            }
        }
    }

    private var permissionDescription: String {
        switch permission {
        case .screenCapture:
            if isGranted {
                return AppText.text("已获得屏幕录制权限，可以使用区域截图、OCR 和图片翻译。")
            }
            return AppText.text("截图需要屏幕录制权限。点击“授权”后，请按系统提示操作。")
        case .directPaste:
            if isGranted {
                return AppText.text("系统已授予自动粘贴所需的授权。")
            }
            return AppText.text("辅助功能权限仅用于将所选内容直接粘贴到其他应用；不授权也可以复制后手动粘贴。")
        }
    }

    // 每次从系统重新读取权限快照；本地 isAwaitingAuthorization 只表示用户正在等待，不是授权依据。
    private func refreshPermissionState() {
        permissionState.status = .current(for: permission)
    }

    private func requestAccess() {
        refreshPermissionState()
        guard !isGranted else { return }
        isAwaitingAuthorization = true
        // 系统重置后也重新发起申请，不能用本地历史跳过系统请求。
        // 请求 API 可能立刻返回、也可能打开系统面板；因此之后立刻刷新一次，并在应用重新激活时再次刷新。
        permission.requestAccess()
        refreshPermissionState()
        if isGranted {
            authorizationDidComplete()
        }
    }

    // 结束等待态；屏幕权限按当前产品流程提供重启入口，自动粘贴权限无需走同一重启提示。
    private func authorizationDidComplete() {
        isAwaitingAuthorization = false
        if permission == .screenCapture {
            presentScreenCaptureRestartPrompt()
        }
    }

    private func presentScreenCaptureRestartPrompt() {
        guard !didPresentScreenCaptureRestartPrompt else { return }
        didPresentScreenCaptureRestartPrompt = true

        NSApp.activate(ignoringOtherApps: true)
        // NSAlert 是 AppKit 的原生模态对话框。runModal 会嵌套运行事件循环并阻塞当前控制流，
        // 适合这个必须等待用户选择后才决定是否重启的短流程；长任务不要使用它。
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = AppText.text("屏幕录制权限已开启")
        alert.informativeText = AppText.text("需要退出并重新打开 iSnipster，新的权限才会生效。")
        alert.addButton(withTitle: AppText.text("退出并重新打开"))
        alert.addButton(withTitle: AppText.text("稍后"))
        // 进入嵌套模态事件循环并等待结果；当前调用栈尚未返回，不能假定弹窗期间所有应用事件都停止。
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // OpenConfiguration 描述“如何启动另一个 app 实例”。此处先启动当前 Bundle 的新实例，
        // 再 terminate 旧进程，避免先退出导致授权后的应用没有重新打开。
        let configuration = NSWorkspace.OpenConfiguration()
        // 请求创建新实例而不是仅激活已有进程；成功回调后再终止旧实例，失败时旧应用仍保持可用。
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            Task { @MainActor in
                if let error {
                    let failureAlert = NSAlert()
                    failureAlert.alertStyle = .warning
                    failureAlert.messageText = AppText.text("重新打开 iSnipster 失败")
                    failureAlert.informativeText = error.localizedDescription
                    failureAlert.addButton(withTitle: AppText.text("好"))
                    failureAlert.runModal()
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

}
