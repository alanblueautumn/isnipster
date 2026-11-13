// 阅读路线
// 这里定义业务层的快捷键数据与注册接口；MacPlatform 将 Set<HotKeyModifier> 翻译成 Carbon 位掩码。
// protocol 类似 Java interface；默认 internal 仅模块内可见，跨 target 调用的类型和成员需要 public。
// 官方参考（协议、协议类型和访问边界）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/protocols/

import Foundation

// Set 类似 TS Set，自动去重；Hashable 允许值用作 Set 成员或 Dictionary 的键。
// Codable 是 Encodable + Decodable，类似带类型校验的序列化契约，不能把它当成任意 JSON 对象。

/// 与平台无关的快捷键值对象；Carbon 常量不会泄漏到应用层。
public enum HotKeyModifier: String, Codable, Sendable, Hashable {
    case command
    case option
    case control
    case shift
}

/// 由物理键码和修饰键集合构成的平台无关快捷键描述。
public struct HotKeyDescriptor: Codable, Sendable, Hashable {
    // let 是只赋值一次的绑定，UInt32 是 32 位无符号整数；Swift 不会把不同数字类型任意隐式转换。
    public let keyCode: UInt32
    public let modifiers: Set<HotKeyModifier>

    // 调用写 HotKeyDescriptor(keyCode: ..., modifiers: ...)，参数标签是 Swift API 的一部分，帮助读出语义。
    public init(keyCode: UInt32, modifiers: Set<HotKeyModifier>) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// 全局快捷键使用 Carbon 适配器实现，这样不需要申请辅助功能权限。
/// 业务层只认识物理键码和逻辑修饰键，不依赖 Carbon 常量。
/// `handler` 是函数类型，对应 Java 的 Runnable；`@MainActor` 是其执行线程契约。
@MainActor
public protocol GlobalHotKeyRegistering: AnyObject {
    func register(
        id: UInt32,
        descriptor: HotKeyDescriptor,
        handler: @escaping @MainActor () -> Void
    ) throws

    func unregister(id: UInt32)

    func unregisterAll()
}
