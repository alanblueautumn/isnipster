// 阅读路线
// SwiftUI 设置行通过 NSViewRepresentable 嵌入 NSButton，按钮成为 first responder 后截取下一次键盘组合。
// 事件修饰键转换成项目的 Set，录制完成经回调交给配置层；录制本身不注册全局热键。
// 官方参考（原生控件桥接生命周期）：https://developer.apple.com/documentation/swiftui/nsviewrepresentable

import AppKit
import MacPlatform
import iSnipsterCore
import SwiftUI

/// 将原生快捷键录制控件桥接到 SwiftUI 设置页。
struct HotKeyRecorder: NSViewRepresentable {
    let descriptor: HotKeyDescriptor
    let onRecord: (HotKeyDescriptor) -> Bool

    // SwiftUI 建立原生视图时调用 makeNSView；创建后通过 updateNSView 同步新状态，不应每次刷新都重建。
    func makeNSView(context: Context) -> HotKeyRecorderControl {
        let control = HotKeyRecorderControl(frame: .zero)
        control.descriptor = descriptor
        control.onRecord = onRecord
        return control
    }

    // 把本轮 SwiftUI 输入同步到已有 NSView；涉及文本/选择时先判断差异，避免无意义赋值打断原生交互。
    func updateNSView(_ nsView: HotKeyRecorderControl, context: Context) {
        nsView.onRecord = onRecord
        if !nsView.isRecording {
            nsView.descriptor = descriptor
        }
    }
}

/// 捕获下一次键盘输入并生成全局快捷键描述的 AppKit 按钮。
final class HotKeyRecorderControl: NSButton {
    var descriptor = HotKeyDescriptor(keyCode: 0, modifiers: []) {
        didSet {
            guard !isRecording else { return }
            updateTitle()
        }
    }
    var onRecord: ((HotKeyDescriptor) -> Bool)?
    private(set) var isRecording = false

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .rounded
        controlSize = .regular
        font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        setButtonType(.momentaryChange)
        focusRingType = .exterior
        updateTitle()
    }

    // NSCoder 初始化用于 Storyboard/XIB 解档；本类型仅支持代码创建，下面明确拒绝解档构造路径。
    required init?(coder: NSCoder) {
        return nil
    }

    // AppKit 鼠标按下回调；event.locationInWindow 属于窗口坐标，传给局部几何计算前需要转换。
    override func mouseDown(with event: NSEvent) {
        isRecording = true
        title = AppText.text("请按快捷键")
        // first responder 是窗口内接收键盘的对象，类似输入焦点；先让窗口可接收键盘，再选择具体控件。
        window?.makeFirstResponder(self)
    }

    // 键盘事件沿 responder chain 分发；这里处理自己认识的键，其余是否交给 super 由后续分支决定。
    override func keyDown(with event: NSEvent) {
        record(event)
    }

    // AppKit 在普通文字输入前尝试派发菜单式快捷键；返回 true 表示已经处理，不再继续分发。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        record(event)
        return true
    }

    private func record(_ event: NSEvent) {
        if event.keyCode == 53 {
            isRecording = false
            updateTitle()
            window?.makeFirstResponder(nil)
            return
        }

        let relevantFlags = event.modifierFlags.intersection([
            .command,
            .option,
            .control,
            .shift,
        ])
        var modifiers: Set<HotKeyModifier> = []
        if relevantFlags.contains(.command) { modifiers.insert(.command) }
        if relevantFlags.contains(.option) { modifiers.insert(.option) }
        if relevantFlags.contains(.control) { modifiers.insert(.control) }
        if relevantFlags.contains(.shift) { modifiers.insert(.shift) }

        let candidate = HotKeyDescriptor(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers
        )
        if onRecord?(candidate) == true {
            descriptor = candidate
        }
        isRecording = false
        updateTitle()
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        isRecording = false
        updateTitle()
        return super.resignFirstResponder()
    }

    private func updateTitle() {
        title = HotKeyDisplay.string(for: descriptor)
    }
}
