import MacShared
import MacPreferences
// 阅读路线
// NSPanel 定义能否成为 key、窗口边界约束和按键分派；HostingView 定义非活动窗口的首击行为。
// AppKit 的 sendEvent 先收到窗口事件，再决定转给文本输入控件还是剪贴板快捷动作。
// 官方参考（NSResponder 事件链）：https://developer.apple.com/documentation/appkit/nsresponder

import AppKit
import SwiftUI

/// AppKit 默认把非活动窗口的首击当成单纯的激活操作。剪贴板卡片属于即时操作，
/// 应允许这一击继续传给 SwiftUI Button。
@MainActor
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    // 控制非 key 窗口的第一击是否直接触发控件；返回 true 可避免必须先激活再点第二次。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

/// 普通无边框 NSPanel 默认不能成为 key window，而且 AppKit 会将窗口限制在
/// visibleFrame 内。底部内容带需要接收搜索键盘输入，并允许覆盖 Dock 区域。
@MainActor
final class BottomShelfPanel: NSPanel {
    var onEscape: (@MainActor () -> Void)?
    var onMoveSelection: (@MainActor (Int) -> Void)?
    var onPasteSelection: (@MainActor (Bool) -> Void)?
    var onPasteIndex: (@MainActor (Int) -> Void)?
    var onFocusSearch: (@MainActor () -> Void)?
    var onPreviewSelection: (@MainActor () -> Void)?

    // key window 是接收键盘的窗口；它与应用是否前台激活、窗口是否可见是不同状态。
    override var canBecomeKey: Bool { true }
    // main window 表示应用的主要文档窗口；工具面板可以接收键盘却不作为 main window。
    override var canBecomeMain: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            let modifiers = event.modifierFlags.intersection([
                .command, .control, .option, .shift
            ])
            if event.keyCode == 3, modifiers == .command {
                onFocusSearch?()
                return
            }
            // Command + 1...9 直接粘贴对应卡片。窗口层优先处理，
            // 不依赖 SwiftUI TextField 当前是否持有 focus。
            if let index = quickPasteIndex(for: event) {
                onPasteIndex?(index)
                return
            }
            switch event.keyCode {
            case 49 where modifiers.isEmpty:
                // 搜索中保留空格和输入法确认；空搜索框或卡片导航状态下打开预览。
                if let textView = firstResponder as? NSTextView,
                   textView.hasMarkedText() || !textView.string.isEmpty {
                    break
                }
                if !event.isARepeat { onPreviewSelection?() }
                return
            case 53:
                onEscape?()
                return
            case 123:
                onMoveSelection?(-1)
                return
            case 124:
                onMoveSelection?(1)
                return
            case 36, 76:
                onPasteSelection?(event.modifierFlags.contains(.shift))
                return
            default:
                break
            }
        }
        super.sendEvent(event)
    }

    private func quickPasteIndex(for event: NSEvent) -> Int? {
        let combinationModifiers = event.modifierFlags.intersection([
            .command, .control, .option, .shift
        ])
        guard combinationModifiers == .command else { return nil }

        return switch event.keyCode {
        // 键盘顶部数字行
        case 18: 0
        case 19: 1
        case 20: 2
        case 21: 3
        case 23: 4
        case 22: 5
        case 26: 6
        case 28: 7
        case 25: 8
        // 独立数字小键盘
        case 83: 0
        case 84: 1
        case 85: 2
        case 86: 3
        case 87: 4
        case 88: 5
        case 89: 6
        case 91: 7
        case 92: 8
        default: nil
        }
    }
}
