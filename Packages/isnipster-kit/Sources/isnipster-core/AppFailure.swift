// 阅读路线
// 用关联值 enum 统一表达取消、权限、不可用、数据和操作错误；错误文案从关联值读取。
// throw / do-catch 类似 Java 异常处理；Swift 的 throws 标在函数签名上，调用处用 try 明确传播。
// 官方参考（Swift 错误传播）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/errorhandling/

import Foundation

// TS 对照：关联值 enum 类似 { kind: "invalidData", message: string } 联合类型。
// LocalizedError 让 error.localizedDescription 读取这里的用户可见文案；throws 类似 Promise reject。

/// 跨 Feature 传递的稳定错误类型。
///
/// macOS 框架通常返回 NSError；如果任由这些错误穿透到 UI，用户最终会看到
/// 无法理解的 framework/domain/code。边界适配器应当把系统错误转换为此类型，
/// 同时只记录错误类型，不记录截图、OCR 文本或剪贴板正文。
///
/// Java 对照：这是一个携带关联数据的 enum，作用接近“sealed interface + 多个
/// record 实现”。例如 `.permissionDenied("原因")` 同时包含类型和值，switch 必须穷举。
// 冒号后是遵循的协议；LocalizedError 提供展示文案，Sendable 声明可以跨并发隔离域传递。
public enum AppFailure: LocalizedError, Sendable {
    case cancelled
    case permissionDenied(String)
    case unavailable(String)
    case invalidData(String)
    case operationFailed(String)

    // String? 等价于 Optional<String>；nil 是“没有值”，访问前需解包，不是能任意调用成员的 Java null。
    public var errorDescription: String? {
        // `case let` 在匹配枚举分支的同时解构关联值，类似 Java record pattern。
        switch self {
        case .cancelled:
            return "操作已取消"
        case let .permissionDenied(message),
             let .unavailable(message),
             let .invalidData(message),
             let .operationFailed(message):
            return message
        }
    }
}
