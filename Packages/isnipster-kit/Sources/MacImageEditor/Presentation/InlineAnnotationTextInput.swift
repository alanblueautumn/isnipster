import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// SwiftUI Binding ↔ Coordinator/NSTextViewDelegate ↔ NSTextView，是原生文字编辑的双向桥。
// 用相同字体、排版宽度和 inset 对齐输入态与提交态；失焦、外部点击和回车需协调避免重复提交。
// 官方参考（NSTextView 原生文字编辑）：https://developer.apple.com/documentation/appkit/nstextview

import AppKit
import ImageEditorFeature
import SwiftUI

private enum InlineTextEditorMetrics {
    static let horizontalInset: CGFloat = 6
    static let verticalInset: CGFloat = 3
    static let caretAllowance: CGFloat = 8
    static let rightMargin: CGFloat = 10
}

/// 本项目用 NSTextView 直接控制文字容器、内边距、焦点和撤销。
/// 输入态与提交态共享排版参数，并补偿 inset，减少字形原点偏移。
@MainActor
private final class InlineAnnotationTextView: NSTextView {
    var onResignFocus: (() -> Void)?

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResignFocus?() }
        return resigned
    }
}

@MainActor
private struct InlineAnnotationTextInput: NSViewRepresentable {
    // @Binding 不另存一份值，而是读写外层状态的通道；可类比 Vue 的受控 v-model。
    @Binding var text: String
    let fontSize: CGFloat
    let color: RGBAColor
    let cursorSession: ScreenshotCursorSession
    let onCommit: () -> Void

    // Coordinator 是桥接期间持续存在的引用对象，用于保存代理和监听；不能把这些状态只放在短生命周期 View 值里。
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    // SwiftUI 建立原生视图时调用 makeNSView；创建后通过 updateNSView 同步新状态，不应每次刷新都重建。
    func makeNSView(context: Context) -> InlineAnnotationTextView {
        let textView = InlineAnnotationTextView(frame: .zero)
        textView.delegate = context.coordinator
        context.coordinator.attach(textView)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(
            width: InlineTextEditorMetrics.horizontalInset,
            height: InlineTextEditorMetrics.verticalInset
        )
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = true
        applyStyle(to: textView)
        return textView
    }

    // 把本轮 SwiftUI 输入同步到已有 NSView；涉及文本/选择时先判断差异，避免无意义赋值打断原生交互。
    func updateNSView(_ textView: InlineAnnotationTextView, context: Context) {
        // SwiftUI 每轮产生新的 View 值；更新 Coordinator 的 parent，让 delegate 使用最新 Binding 和回调。
        context.coordinator.parent = self
        context.coordinator.observeWindow(textView.window)
        // 仅在内容真正不同才同步，避免每次视图刷新都重设 selection、光标或正在进行的输入法组合。
        if textView.string != text {
            textView.string = text
            textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
        }
        applyStyle(to: textView)

        guard context.coordinator.needsInitialFocus else { return }
        context.coordinator.needsInitialFocus = false
        let coordinator = context.coordinator
        // 把闭包排到主队列稍后执行；常用于等待当前布局/焦点切换结束，不会创建后台工作线程。
        DispatchQueue.main.async { [weak textView, weak coordinator] in
            guard let textView, let window = textView.window,
                  let coordinator, !coordinator.hasFinished else { return }
            coordinator.observeWindow(window)
            // first responder 是窗口内接收键盘的对象，类似输入焦点；先让窗口可接收键盘，再选择具体控件。
            window.makeFirstResponder(textView)
        }
    }

    // 桥接视图移出层级时清理回调与监听；类似 Vue onUnmounted，ARC 本身不会帮忙注销事件。
    static func dismantleNSView(_ textView: InlineAnnotationTextView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    /// 同时设置现有文字、后续输入文字和插入光标的颜色/字体，避免只有已输入内容更新样式。
    private func applyStyle(to textView: NSTextView) {
        let font = NSFont(name: "Helvetica Neue Medium", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let textColor = NSColor(
            srgbRed: color.red,
            green: color.green,
            blue: color.blue,
            alpha: color.alpha
        )
        textView.font = font
        textView.textColor = textColor
        textView.insertionPointColor = textColor
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: textColor
        ]
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InlineAnnotationTextInput
        var needsInitialFocus = true
        private(set) var hasFinished = false
        private weak var textView: InlineAnnotationTextView?
        private weak var observedWindow: NSWindow?
        private var outsideClickMonitor: Any?

        init(parent: InlineAnnotationTextInput) {
            self.parent = parent
        }

        /// 原生文本变化后写回 Binding；这是 AppKit → SwiftUI 方向，与 updateNSView 的同步方向相反。
        func textDidChange(_ notification: Notification) {
            guard !hasFinished, let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        /// 响应原生编辑结束通知；本项目回车由截图快捷键处理，不能在此再解释为一次回车提交。
        func textDidEndEditing(_ notification: Notification) {
            // 这里只响应真实焦点离开；回车属于截图会话快捷键，由 Controller 统一处理。
            finishEditing()
        }

        func attach(_ textView: InlineAnnotationTextView) {
            self.textView = textView
            textView.onResignFocus = { [weak self] in
                self?.finishEditing()
            }
            // local monitor 在本应用派发事件前执行；返回 nil 消费事件，返回 event 才继续交给 responder chain。
            outsideClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self, !self.hasFinished,
                      let textView = self.textView, let window = textView.window,
                      window.isVisible, !textView.isHiddenOrHasHiddenAncestor else { return event }
                let isCanvasClick = event.window === window
                if isCanvasClick {
                    // 坐标转换中的 nil 表示所属窗口坐标系，不表示屏幕坐标；跨到屏幕还需窗口转换 API。
                    let point = textView.convert(event.locationInWindow, from: nil)
                    if textView.bounds.contains(point) { return event }
                }
                self.finishEditing(releasesFocus: true)
                // 画布上的这次按下只结束输入，不能再启动新增文字或移动文字手势。
                // 工具栏等其他窗口的按钮仍正常接收点击。
                return isCanvasClick ? nil : event
            }
        }

        /// 使用 hasFinished 做幂等结束，先取最后文本，再注销监听并通知提交。
        private func finishEditing(releasesFocus: Bool = false) {
            guard !hasFinished else { return }
            // 先标记已结束，再切焦点和回调；这些操作可能触发新的失焦通知，标记用于阻止重复提交。
            hasFinished = true
            if let textView { parent.text = textView.string }
            stopObservingWindow()
            removeOutsideClickMonitor()
            if releasesFocus, let textView, let window = textView.window,
               window.firstResponder === textView {
                window.makeFirstResponder(window.contentView)
            }
            parent.onCommit()
            parent.cursorSession.refresh(afterTransition: true)
        }

        /// 拆除桥接时清空 delegate、监听和闭包，防止已经结束的文本框继续回写 session。
        func invalidate() {
            hasFinished = true
            stopObservingWindow()
            removeOutsideClickMonitor()
            textView?.onResignFocus = nil
            textView?.delegate = nil
            textView = nil
        }

        private func removeOutsideClickMonitor() {
            if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
            outsideClickMonitor = nil
        }

        /// 文本框真正进入窗口后订阅失去 key 的通知；换窗口时先注销旧观察对象。
        func observeWindow(_ window: NSWindow?) {
            guard !hasFinished, let window, observedWindow !== window else { return }
            stopObservingWindow()
            observedWindow = window
            // NotificationCenter 是进程内通知中心，类似事件总线；注册形式不同，清理时使用的对象/token 也不同。
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }

        /// 按通知名和窗口对象移除订阅，保留其他不相关的 NotificationCenter 监听。
        func stopObservingWindow() {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: observedWindow
            )
            observedWindow = nil
        }

        @objc private func windowDidResignKey(_ notification: Notification) {
            finishEditing(releasesFocus: true)
        }
    }
}

extension InlineEditorCanvas {
    /// 输入框直接覆盖在截图落点上；提交后只留下透明背景的文字标注。
    func inlineTextEditor(origin: CGPoint, canvasSize: CGSize) -> some View {
        let imageSize = session.document.imageSize
        let scaleX = canvasSize.width / max(imageSize.width, 1)
        let scaleY = canvasSize.height / max(imageSize.height, 1)
        let displayOrigin = CGPoint(x: origin.x * scaleX, y: origin.y * scaleY)
        let editorFont = NSFont(name: "Helvetica Neue Medium", size: session.textFontSize)
            ?? NSFont.systemFont(ofSize: session.textFontSize, weight: .medium)
        // 默认内容宽度约为 4 个当前字号，随输入增长，最大到选区右边缘前 10pt。
        let minimumContentWidth = session.textFontSize * 4
        let maximumEditorWidth = max(
            InlineTextEditorMetrics.horizontalInset * 2 + 1,
            canvasSize.width
                - displayOrigin.x
                - InlineTextEditorMetrics.rightMargin
                + InlineTextEditorMetrics.horizontalInset
        )
        let desiredContentWidth = max(
            minimumContentWidth,
            ceil((session.textValue as NSString).size(withAttributes: [.font: editorFont]).width)
                + InlineTextEditorMetrics.caretAllowance
        )
        let editorWidth = min(
            desiredContentWidth + InlineTextEditorMetrics.horizontalInset * 2,
            maximumEditorWidth
        )
        let contentLayoutWidth = max(
            1,
            editorWidth - InlineTextEditorMetrics.horizontalInset * 2
        )
        let lineHeight = ceil(editorFont.ascender - editorFont.descender + editorFont.leading)
        let textBounds = (session.textValue as NSString).boundingRect(
            with: CGSize(width: contentLayoutWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: editorFont]
        )
        let contentHeight = max(lineHeight, ceil(textBounds.height))
        let editorHeight = contentHeight + InlineTextEditorMetrics.verticalInset * 2
        let displayContentSize = CGSize(width: contentLayoutWidth, height: contentHeight)
        let entryID = session.textEntryID

        return InlineAnnotationTextInput(
            // Binding(get:set:) 将现有状态投影为控件需要的值；类似 Vue computed 的读写代理。
            text: Binding(
                get: { session.textValue },
                set: { value in
                    guard let entryID, session.textEntryID == entryID else { return }
                    session.textValue = value
                }
            ),
            fontSize: session.textFontSize,
            color: session.document.strokeStyle.color,
            cursorSession: session.cursorSession,
            onCommit: {
                guard let entryID else { return }
                session.commitTextEntry(matching: entryID)
            }
        )
            // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
            .frame(width: editorWidth, height: editorHeight, alignment: .topLeading)
            // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
            .overlay {
                // 微信截图风格：黑色虚线框只表示编辑区域，不参与文字排版。
                Rectangle()
                    .stroke(
                        Color.black.opacity(0.9),
                        style: SwiftUI.StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            // 输入框向左上补偿自身 padding，字形仍从用户点击位置开始，提交后不会偏移。
            .offset(
                x: displayOrigin.x - InlineTextEditorMetrics.horizontalInset,
                y: displayOrigin.y - InlineTextEditorMetrics.verticalInset
            )
            // 显式指定视图身份；值变化可让 SwiftUI 重建该子树的局部状态，不只是换一个显示标签。
            .id(session.textEntryID)
            // 视图进入显示层级时执行，可重复触发；需要一次性语义的业务逻辑仍应由状态或服务保证。
            .onAppear {
                session.textEntryDisplayContentSize = displayContentSize
            }
            // onChange 类似 Vue watch：状态变化后执行副作用；仅监听值变化，不代表每次 body 求值都会调用。
            .onChange(of: displayContentSize) { _, newSize in
                if session.textEntryDisplayContentSize != newSize {
                    session.textEntryDisplayContentSize = newSize
                }
            }
    }
}
