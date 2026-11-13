// 阅读路线
// 这是跨启动保存的配置 DTO；ImageDocument 持有运行时文档，二者通过配置回调连接。
// Codable 让编译器合成编码/解码；字典缺项不代表非法，文档读取时还会使用默认笔触。
// 官方参考（UserDefaults 小型偏好存储）：https://developer.apple.com/documentation/foundation/userdefaults

import CoreGraphics
import Foundation

/// 截图编辑工具栏中允许跨应用重启保留的“配置快照”。
///
/// 这里只保存颜色、粗细和工具模式等少量元数据，绝不保存截图、OCR 文本、剪贴板内容、
/// 选区坐标或撤销栈。Java 对照：这是一个可序列化的 Preferences DTO，不是编辑文档实体。
public struct EditorPreferences: Codable, Sendable, Equatable {
    /// 每个工具独立记忆颜色；打码默认使用蓝色，其余工具默认使用红色。
    public var perToolStrokeColor: [EditorTool: RGBAColor]

    /// 每个工具独立记忆粗细。未出现的工具继续使用 StrokeStyle 的默认值 4。
    public var perToolStrokeWidth: [EditorTool: CGFloat]

    /// 矩形工具的填充与形状配置。
    public var shapeIsFilled: Bool
    public var annotationShape: AnnotationShape

    /// 箭头工具在“实心箭头”和“普通直线”之间的选择。
    public var arrowMode: ArrowMode

    public init(
        perToolStrokeColor: [EditorTool: RGBAColor] = [:],
        perToolStrokeWidth: [EditorTool: CGFloat] = [:],
        shapeIsFilled: Bool = false,
        annotationShape: AnnotationShape = .rectangle,
        arrowMode: ArrowMode = .arrow
    ) {
        self.perToolStrokeColor = perToolStrokeColor
        self.perToolStrokeWidth = perToolStrokeWidth
        self.shapeIsFilled = shapeIsFilled
        self.annotationShape = annotationShape
        self.arrowMode = arrowMode
    }
}

/// 编辑功能层只声明配置存取端口，不依赖 UserDefaults 等 macOS API。
///
/// Java 对照：相当于 Repository 接口。MacPlatform 提供实现，CompositionRoot 负责注入。
/// 配置只由主线程上的工具栏读写，因此协议明确隔离到 MainActor，避免无意义的并发锁。
@MainActor
public protocol EditorPreferencesStoring: AnyObject {
    func load() -> EditorPreferences
    func save(_ preferences: EditorPreferences)
}
