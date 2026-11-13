import MacShared
import MacPreferences
// 阅读路线
// 把自动粘贴授权选择包成独立窗口，并用 ClipboardPastePermissionResponse 回调把用户意图交回 Presenter。
// 窗口关闭与按钮选择都可能结束流程，完成回调要避免重复；截图期间可临时隐藏再恢复。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import SwiftUI

@MainActor
final class DirectPastePermissionWindowController: NSWindowController, NSWindowDelegate {
    private var onResponse: (@MainActor (ClipboardPastePermissionResponse) -> Void)?
    private var isSuspendedForCapture = false

    init(destinationName: String?, onResponse: @escaping @MainActor (ClipboardPastePermissionResponse) -> Void) {
        self.onResponse = onResponse
        let panel = DirectPastePermissionPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)

        let title = destinationName.map { AppText.format("你想直接粘贴到“%@”吗？", $0) }
            ?? AppText.text("你想直接粘贴到其他应用吗？")
        let rootView = DirectPastePermissionView(
            title: title,
            onEnableAccess: { [weak self] in self?.finish(.enableAccess) },
            onCopyOnly: { [weak self] in self?.finish(.copyOnly) }
        )
        let hostingView = DirectPastePermissionHostingView(rootView: rootView)
        panel.contentView = hostingView
        panel.setContentSize(hostingView.fittingSize)
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // 关闭时是否自动释放是 AppKit 的窗口生命周期选项；控制器若要复用窗口，会显式保留并自行管理引用。
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        // 允许面板仅在控件需要键盘时取得 key；按钮点击与输入框输入不一定需要相同的焦点策略。
        panel.becomesKeyOnlyIfNeeded = false
        panel.isFloatingPanel = true
        // 决定应用失去激活状态时是否自动隐藏面板；隐藏不等于关闭，也不会自动释放会话状态。
        panel.hidesOnDeactivate = false
        // level 决定窗口相对其他层级的前后位置；同层窗口的顺序还由 orderFront/子窗口关系决定。
        panel.level = .screenSaver
        // 控制窗口在 Spaces 与全屏空间中的参与方式；不是 SwiftUI 中的子视图布局属性。
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // 指定系统对窗口显示/隐藏采用的动画行为；与内容图层 CABasicAnimation 是不同层面的动画。
        panel.animationBehavior = .none
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
    }

    @available(*, unavailable)
    // NSCoder 初始化用于 Storyboard/XIB 解档；本类型仅支持代码创建，下面明确拒绝解档构造路径。
    required init?(coder: NSCoder) { return nil }

    func show(above shelfFrame: NSRect?, on screen: NSScreen) {
        guard let window, onResponse != nil, !isSuspendedForCapture else { return }
        if !window.isVisible {
            let visibleFrame = screen.visibleFrame
            let size = window.frame.size
            let preferredY = max(
                visibleFrame.midY - size.height / 2,
                shelfFrame.map { $0.maxY + 12 } ?? visibleFrame.minY
            )
            window.setFrameOrigin(NSPoint(
                x: max(visibleFrame.minX, visibleFrame.midX - size.width / 2),
                y: max(visibleFrame.minY, min(preferredY, visibleFrame.maxY - size.height))
            ))
        }

        // 非激活面板直接接收键盘焦点，不与原应用进行前台激活竞争。
        window.makeKeyAndOrderFront(nil)
        // 把闭包排到主队列稍后执行；常用于等待当前布局/焦点切换结束，不会创建后台工作线程。
        DispatchQueue.main.async { [weak self] in
            guard let self, self.onResponse != nil,
                  !self.isSuspendedForCapture, let window = self.window,
                  window.isVisible else { return }
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// 截图期间暂时隐藏授权提示；保留控制器以便截图结束后恢复。
    func suspendForCapture() {
        isSuspendedForCapture = true
    }

    /// 恢复截图前暂存的提示展示状态，避免截图选区阶段争抢窗口焦点。
    func resumeAfterCapture() {
        isSuspendedForCapture = false
    }

    /// 由外层主动收起，不把程序关闭再解释为用户选择一个授权按钮。
    func closeWithoutResponse() {
        onResponse = nil
        close()
    }

    func windowWillClose(_ notification: Notification) {
        let callback = onResponse
        onResponse = nil
        callback?(.dismiss)
    }

    /// 取出用户选择并结束窗口流程，后续权限请求由调用方决定。
    private func finish(_ response: ClipboardPastePermissionResponse) {
        guard !isSuspendedForCapture, let callback = onResponse else { return }
        onResponse = nil
        close()
        callback(response)
    }
}

@MainActor
private final class DirectPastePermissionPanel: NSPanel {
    // key window 是接收键盘的窗口；它与应用是否前台激活、窗口是否可见是不同状态。
    override var canBecomeKey: Bool { true }
    // main window 表示应用的主要文档窗口；工具面板可以接收键盘却不作为 main window。
    override var canBecomeMain: Bool { false }
}

@MainActor
private final class DirectPastePermissionHostingView: NSHostingView<DirectPastePermissionView> {
    // 控制非 key 窗口的第一击是否直接触发控件；返回 true 可避免必须先激活再点第二次。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct DirectPastePermissionView: View {
    let title: String
    let onEnableAccess: @MainActor () -> Void
    let onCopyOnly: @MainActor () -> Void

    // @AppStorage 将偏好属性连接到 UserDefaults，并让 View 响应变化；等号后的值是未保存时的默认值。
    @AppStorage(AppPreferences.Clipboard.suppressesDirectPastePermissionPrompt.name)
    private var suppressesPrompt = false

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        VStack(spacing: 18) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .scaledToFit()
                // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                .frame(width: 64, height: 64)
                // 控制辅助功能树中的可见性，不改变屏幕显示；装饰图标可隐藏，动作语义由外层按钮提供。
                .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 22, weight: .semibold))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(AppText.text("现在不方便手动粘贴？启用无障碍访问后，iSnipster 可将所选内容直接粘贴到目标应用；也可以仅复制到剪切板。"))
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button(AppText.text("启用无障碍访问"), action: onEnableAccess)
                    .buttonStyle(DirectPastePermissionButtonStyle(isPrimary: true))
                    .keyboardShortcut(.defaultAction)
                Button(AppText.text("复制到剪切板"), action: onCopyOnly)
                    .buttonStyle(DirectPastePermissionButtonStyle(isPrimary: false))
                    .keyboardShortcut(.cancelAction)
            }

            Toggle(AppText.text("不在询问"), isOn: $suppressesPrompt)
                .toggleStyle(.checkbox)
                .font(.system(size: 13))
        }
        // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
        .padding(.horizontal, 28)
        .padding(.top, 36)
        .padding(.bottom, 26)
        .frame(width: 480)
        // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// 非激活面板保留明确的主次按钮样式，不依赖应用是否拥有主窗口。
private struct DirectPastePermissionButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: isPrimary ? .semibold : .regular))
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                isPrimary ? Color.blue : Color(nsColor: .controlColor),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
