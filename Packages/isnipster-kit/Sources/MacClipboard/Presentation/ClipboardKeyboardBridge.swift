import MacShared
import MacPreferences
// 阅读路线
// 用 Combine 事件把 NSPanel 捕获的键盘动作传给 SwiftUI，避免窗口直接调用具体 View 方法。
// Subject 类似 RxJS Subject/EventEmitter；它发送动作，不负责存储历史业务状态。
// 官方参考（Combine Publisher/Subject）：https://developer.apple.com/documentation/combine

import Combine

/// 将 NSPanel 捕获的键盘动作转发为 SwiftUI 可订阅的 Combine 事件。
@MainActor
final class ClipboardKeyboardBridge {
    let moveSelection = PassthroughSubject<Int, Never>()
    let pasteSelection = PassthroughSubject<Bool, Never>()
    let pasteIndex = PassthroughSubject<Int, Never>()
    let focusSearch = PassthroughSubject<Void, Never>()
    let previewSelection = PassthroughSubject<Void, Never>()
}
