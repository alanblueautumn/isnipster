import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 截图会话内的动作目录、默认键位及持久化；实际分发在 InlineScreenshotController+Keyboard。
// 与 AppShortcutAction 的系统全局热键分开；固定动作不能被用户配置覆盖。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import Foundation
import ImageEditorFeature
import iSnipsterCore

/// 截图工具栏中可以直接通过键盘切换或执行的工具。
public enum ScreenshotToolShortcutAction: String, CaseIterable, Codable, Sendable, Identifiable {
    case rectangle
    case arrow
    case pen
    case text
    case step
    case translation
    case ocr
    case colorPicker
    case redaction
    case pin
    case undo
    case redo
    case copyFile
    case cancel
    case copy

    public var id: String { rawValue }

    public var isCustomizable: Bool {
        self != .cancel && self != .copy
    }

    public var title: String {
        switch self {
        case .rectangle: AppText.text("矩形")
        case .arrow: AppText.text("箭头")
        case .pen: AppText.text("画笔")
        case .text: AppText.text("标注文本")
        case .step: AppText.text("标注步骤")
        case .translation: AppText.text(.screenshotTranslation)
        case .ocr: AppText.text(.ocr)
        case .colorPicker: AppText.text("吸管取色")
        case .redaction: AppText.text(.redact)
        case .pin: AppText.text(.pin)
        case .undo: AppText.text(.undo)
        case .redo: AppText.text(.redo)
        case .copyFile: AppText.text(.copyFile)
        case .cancel: AppText.text(.cancel)
        case .copy: AppText.text(.finishAndCopy)
        }
    }

    public var defaultDescriptor: HotKeyDescriptor {
        switch self {
        case .rectangle: HotKeyDescriptor(keyCode: 18, modifiers: []) // 1
        case .arrow: HotKeyDescriptor(keyCode: 19, modifiers: []) // 2
        case .pen: HotKeyDescriptor(keyCode: 20, modifiers: []) // 3
        case .text: HotKeyDescriptor(keyCode: 21, modifiers: []) // 4
        case .step: HotKeyDescriptor(keyCode: 23, modifiers: []) // 5
        case .translation: HotKeyDescriptor(keyCode: 22, modifiers: []) // 6
        case .ocr: HotKeyDescriptor(keyCode: 26, modifiers: []) // 7
        case .colorPicker: HotKeyDescriptor(keyCode: 28, modifiers: []) // 8
        case .redaction: HotKeyDescriptor(keyCode: 25, modifiers: []) // 9
        case .pin: HotKeyDescriptor(keyCode: 29, modifiers: []) // 0
        case .undo: HotKeyDescriptor(keyCode: 6, modifiers: [.command])
        case .redo: HotKeyDescriptor(keyCode: 6, modifiers: [.command, .shift])
        case .copyFile: HotKeyDescriptor(keyCode: 1, modifiers: [.command])
        case .cancel: HotKeyDescriptor(keyCode: 53, modifiers: [])
        case .copy: HotKeyDescriptor(keyCode: 36, modifiers: [])
        }
    }

    var editorTool: EditorTool? {
        switch self {
        case .rectangle: .rectangle
        case .arrow: .arrow
        case .pen: .pen
        case .redaction: .redaction
        case .text: .text
        case .step: .step
        case .colorPicker: .colorPicker
        case .ocr, .translation, .pin, .undo, .redo, .copyFile, .cancel, .copy: nil
        }
    }
}

/// 负责从 UserDefaults 读取和写入截图工具快捷键配置。
public enum ScreenshotToolShortcutStore {
    private static let key = "isnipster.screenshotToolShortcuts.v4"

    /// 以默认动作表为基础载入保存值；固定动作由本文件规则控制，避免配置改变结束/撤销等基本语义。
    public static func load() -> [ScreenshotToolShortcutAction: HotKeyDescriptor] {
        var shortcuts = Dictionary(
            uniqueKeysWithValues: ScreenshotToolShortcutAction.allCases.map {
                ($0, $0.defaultDescriptor)
            }
        )
        guard let data = UserDefaults.standard.data(forKey: key),
              // Property List 是 Apple 常见结构化配置格式；Decoder 按 Codable 类型还原，不是执行文件内的 Swift 代码。
              let stored = try? PropertyListDecoder().decode(
                  [String: HotKeyDescriptor].self,
                  from: data
              ) else {
            return shortcuts
        }
        for (rawValue, descriptor) in stored {
            guard let action = ScreenshotToolShortcutAction(rawValue: rawValue),
                  action.isCustomizable else { continue }
            shortcuts[action] = descriptor
        }
        return shortcuts
    }

    /// 把可保存的动作键位编码到 UserDefaults；真正匹配事件由截图控制器完成。
    public static func save(_ shortcuts: [ScreenshotToolShortcutAction: HotKeyDescriptor]) {
        let stored = Dictionary(
            uniqueKeysWithValues: shortcuts.filter { $0.key.isCustomizable }.map { ($0.key.rawValue, $0.value) }
        )
        // 将 Codable 值序列化为 plist；可选择 XML 或二进制，读取方都用相应 Decoder 还原类型。
        guard let data = try? PropertyListEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

/// 把截图工具快捷键转换为面向用户的显示文本。
enum ScreenshotToolShortcutDisplay {
    static func string(for descriptor: HotKeyDescriptor) -> String {
        var value = ""
        if descriptor.modifiers.contains(.control) { value += "⌃" }
        if descriptor.modifiers.contains(.option) { value += "⌥" }
        if descriptor.modifiers.contains(.shift) { value += "⇧" }
        if descriptor.modifiers.contains(.command) { value += "⌘" }
        value += keyTitle(for: descriptor.keyCode)
        return value
    }

    private static func keyTitle(for keyCode: UInt32) -> String {
        switch keyCode {
        case 0: "A"
        case 1: "S"
        case 2: "D"
        case 3: "F"
        case 4: "H"
        case 5: "G"
        case 6: "Z"
        case 7: "X"
        case 8: "C"
        case 9: "V"
        case 11: "B"
        case 12: "Q"
        case 13: "W"
        case 14: "E"
        case 15: "R"
        case 16: "Y"
        case 17: "T"
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 22: "6"
        case 23: "5"
        case 24: "="
        case 25: "9"
        case 26: "7"
        case 27: "-"
        case 28: "8"
        case 29: "0"
        case 30: "]"
        case 31: "O"
        case 32: "U"
        case 33: "["
        case 34: "I"
        case 35: "P"
        case 36: "↩"
        case 37: "L"
        case 38: "J"
        case 39: "'"
        case 40: "K"
        case 41: ";"
        case 42: "\\"
        case 43: ","
        case 44: "/"
        case 45: "N"
        case 46: "M"
        case 47: "."
        case 48: "⇥"
        case 49: "Space"
        case 50: "`"
        case 51: "⌫"
        case 53: "Esc"
        case 96: "F5"
        case 97: "F6"
        case 98: "F7"
        case 99: "F3"
        case 100: "F8"
        case 101: "F9"
        case 103: "F11"
        case 109: "F10"
        case 111: "F12"
        case 118: "F4"
        case 120: "F2"
        case 122: "F1"
        case 123: "←"
        case 124: "→"
        case 125: "↓"
        case 126: "↑"
        default: "#\(keyCode)"
        }
    }
}
