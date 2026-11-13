// 阅读路线
// 加载路径是默认映射 → 解码磁盘配置 → 覆盖已知动作；保存走枚举键到字符串键的转换。
// UserDefaults 类似应用级 localStorage；PropertyListEncoder 将有类型的值转成 Data 后交给它保存。
// 官方参考（UserDefaults 小型偏好存储）：https://developer.apple.com/documentation/foundation/userdefaults

import Foundation
import iSnipsterCore

/// 使用 UserDefaults 持久化应用级全局快捷键。
enum AppShortcutStore {
    private static let key = "isnipster.globalShortcuts.v2"

    static func load() -> [AppShortcutAction: HotKeyDescriptor] {
        // 先生成完整默认映射，再覆盖已保存的动作；损坏或缺失配置时仍有可用结果。
        var shortcuts = Dictionary(
            uniqueKeysWithValues: AppShortcutAction.allCases.map {
                ($0, $0.defaultDescriptor)
            }
        )
        // guard let 同时判断是否有值并解包；else 必须退出当前路径，后面的 data 因而是非 Optional。
        // try? 把解码错误转为 nil，这里有意把损坏配置作为“使用默认值”处理。
        guard let data = UserDefaults.standard.data(forKey: key),
              // Property List 是 Apple 常见结构化配置格式；Decoder 按 Codable 类型还原，不是执行文件内的 Swift 代码。
              let stored = try? PropertyListDecoder().decode(
                  [String: HotKeyDescriptor].self,
                  from: data
              ) else {
            return shortcuts
        }
        for (rawValue, descriptor) in stored {
            guard let action = AppShortcutAction(rawValue: rawValue) else { continue }
            shortcuts[action] = descriptor
        }
        return shortcuts
    }

    static func save(_ shortcuts: [AppShortcutAction: HotKeyDescriptor]) {
        // 把枚举键转为 String，形成 Property List 可编码的字典；这一步类似 DTO 序列化前的字段转换。
        let stored = Dictionary(
            uniqueKeysWithValues: shortcuts.map { ($0.key.rawValue, $0.value) }
        )
        // 将 Codable 值序列化为 plist；可选择 XML 或二进制，读取方都用相应 Decoder 还原类型。
        guard let data = try? PropertyListEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
