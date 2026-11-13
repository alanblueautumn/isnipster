// 阅读路线
// 此文件只格式化显示文本；是否注册成功由 CarbonHotKeyService 决定。
// 修饰键按固定顺序拼接，最后查键码表；default 保留未知数字，避免菜单出现空标签。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import iSnipsterCore

/// 把底层键码和修饰键组合转换为菜单与设置页显示文本。
enum HotKeyDisplay {
    static func string(for descriptor: HotKeyDescriptor) -> String {
        var value = ""
        if descriptor.modifiers.contains(.control) { value += "⌃" }
        if descriptor.modifiers.contains(.option) { value += "⌥" }
        if descriptor.modifiers.contains(.shift) { value += "⇧" }
        if descriptor.modifiers.contains(.command) { value += "⌘" }
        value += keyTitle(for: descriptor.keyCode)
        return value
    }

    // switch 的每个分支直接返回字符串；键码按固定键位显示，不会查询用户当前输入法布局。
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
