// 阅读路线
// ClipboardContent 表达内容种类，Entry 增加历史身份，Snapshot 表达一次采集，PasteboardClient 定义系统读写端口。
// 可类比 TS 带 kind 的联合类型；switch 解构关联值，避免 Java Object payload 的运行时强转。
// 官方参考（Swift 结构体与类）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/

import Foundation

/// 剪贴板内容的封闭联合类型。
///
/// Java 对照：可理解为 sealed interface ClipboardContent，以及 Text/Url/Image/Files/Color
/// 五个 record。关联值让内容和类型绑定在一起，避免 `type + Object payload` 的强转。
public enum ClipboardContent: Sendable, Equatable, Codable {
    case text(String)
    case url(URL)
    case imagePNG(Data, pixelWidth: Int, pixelHeight: Int)
    case files([URL])
    case color(String)

    /// 浏览器地址栏常常只向剪贴板写入普通字符串。这里仅把“整段内容就是一个
    /// http/https 地址”的文本识别为网页链接，避免把正文中的网址误判成链接卡片。
    public static func detectedWebURL(in text: String) -> URL? {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty,
              !candidate.contains(where: \.isWhitespace),
              // URLComponents 分开管理路径与查询参数，再生成转义后的 URL；类似后端 URI builder。
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        return components.url
    }

    /// 指纹是一种带类型标签的序列化，相当于 TS 的 discriminated union。
    /// 每段内容加上字节长度，避免文件名中的换行符与“多个文件的分隔符”混淆。
    /// 来源应用和采集时间不参与去重；同一内容从不同应用复制仍视为同一条。
    // 这是待哈希的规范字节表示；Data 类似 byte[]，UTF-8 编码长度与 Swift 字符数可能不同。
    public var deduplicationData: Data {
        var result = Data()
        func append(_ value: Data) {
            // 长度前缀固定用大端编码，保证分段边界明确；并不是直接拼接多个可能含分隔符的字符串。
            var length = UInt64(value.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(value)
        }
        func appendString(_ value: String) { append(Data(value.utf8)) }
        switch self {
        case let .text(value):
            appendString("text")
            appendString(value)
        case let .url(value):
            appendString("url")
            appendString(value.absoluteString)
        case let .imagePNG(data, _, _):
            appendString("imagePNG")
            append(data)
        case let .files(urls):
            appendString("files")
            urls.forEach { appendString($0.absoluteString) }
        case let .color(value):
            appendString("color")
            appendString(value)
        }
        return result
    }

    public var estimatedBytes: Int {
        // switch 必须处理每个 case；以后新增内容类型时，编译器会指出所有遗漏位置。
        switch self {
        case let .text(value), let .color(value):
            return value.utf8.count
        case let .url(url):
            return url.absoluteString.utf8.count
        case let .imagePNG(data, _, _):
            return data.count
        case let .files(urls):
            return urls.reduce(0) { $0 + $1.path.utf8.count }
        }
    }

    public var searchText: String {
        switch self {
        case let .text(value), let .color(value): return value
        case let .url(url): return url.absoluteString
        case let .files(urls): return urls.map(\.lastPathComponent).joined(separator: " ")
        case .imagePNG: return "图片"
        }
    }

    /// 需要“纯文本粘贴”时使用的降级表示。图片没有合理的纯文本表示。
    public var plainTextValue: String? {
        switch self {
        case let .text(value), let .color(value):
            return value
        case let .url(url):
            return url.absoluteString
        case let .files(urls):
            return urls.map(\.path).joined(separator: "\n")
        case .imagePNG:
            return nil
        }
    }
}

/// 一条历史记录。Identifiable 让 SwiftUI ForEach 用稳定 id 做增量刷新。
public struct ClipboardEntry: Sendable, Identifiable, Equatable, Codable {
    public let id: UUID
    public let capturedAt: Date
    public var usageCount: Int
    public var isFavorite: Bool
    public var categoryID: UUID?
    public let fingerprint: String
    public let content: ClipboardContent
    public let sourceApplicationName: String?
    public let sourceBundleIdentifier: String?

    public init(
        id: UUID = UUID(),
        capturedAt: Date = .now,
        usageCount: Int = 1,
        isFavorite: Bool = false,
        categoryID: UUID? = nil,
        fingerprint: String,
        content: ClipboardContent,
        sourceApplicationName: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.usageCount = usageCount
        self.isFavorite = isFavorite
        self.categoryID = categoryID
        self.fingerprint = fingerprint
        self.content = content
        self.sourceApplicationName = sourceApplicationName
        self.sourceBundleIdentifier = sourceBundleIdentifier
    }
}

/// 一次读取取得的内容和来源应用快照；changeCount 由 Controller 单独跟踪。
public struct ClipboardSnapshot: Sendable {
    public let content: ClipboardContent
    public let sourceApplicationName: String?
    public let sourceBundleIdentifier: String?

    public init(
        content: ClipboardContent,
        sourceApplicationName: String? = nil,
        sourceBundleIdentifier: String? = nil
    ) {
        self.content = content
        self.sourceApplicationName = sourceApplicationName
        self.sourceBundleIdentifier = sourceBundleIdentifier
    }
}

/// 本项目把剪贴板访问统一隔离到 MainActor，Feature 通过这个端口隔离 AppKit。
/// Java 对照：这是 Repository/Gateway 接口；Feature 不需要知道 NSPasteboard 类型。
@MainActor
public protocol PasteboardClient: AnyObject {
    var changeCount: Int { get }
    func readSnapshot(maxBytes: Int) async -> ClipboardSnapshot?
    func write(_ content: ClipboardContent) throws
    func writeImage(_ content: ClipboardContent) async throws
}

public extension PasteboardClient {
    func writeImage(_ content: ClipboardContent) async throws { try write(content) }
}
