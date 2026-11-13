// 阅读路线
// 新增应用级动作时同时考虑标题、系统注册 ID 和默认键位；三者描述同一动作的不同用途。
// CaseIterable 生成 allCases 供设置页遍历，Identifiable 提供界面身份，String 原始值用于持久化。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import MacPlatform
import iSnipsterCore

/// 可配置全局快捷键的应用级动作。
enum AppShortcutAction: String, CaseIterable, Identifiable {
    case capture
    case clipboard
    case textTranslation

    // rawValue 是枚举的字符串值；id 供 SwiftUI 区分行，hotKeyID 则是向 Carbon 注册时使用的编号。
    var id: String { rawValue }

    var title: String {
        switch self {
        case .capture: AppText.text("截图并编辑")
        case .clipboard: AppText.text("剪贴板历史")
        case .textTranslation: AppText.text("文本翻译")
        }
    }

    var hotKeyID: UInt32 {
        switch self {
        case .capture: 1
        case .clipboard: 3
        case .textTranslation: 5
        }
    }

    // 这些数字是 macOS 虚拟键码，不是 ASCII：99 对应 F3，9 对应 V，118 对应 F4。
    var defaultDescriptor: HotKeyDescriptor {
        switch self {
        case .capture:
            HotKeyDescriptor(keyCode: 99, modifiers: [])
        case .clipboard:
            HotKeyDescriptor(keyCode: 9, modifiers: [.command, .shift])
        case .textTranslation:
            HotKeyDescriptor(keyCode: 118, modifiers: [])
        }
    }
}
