// 阅读路线
// 先读 commit / undo / redo，再读 replaceOriginal：编辑历史保存基底图与命令数组的快照。
// 文档相当于受控 store；public private(set) 允许界面读取、禁止外部绕过方法修改操作集合。
// 官方参考（Observation）：https://developer.apple.com/documentation/observation

import CoreGraphics
import Foundation
import Observation
import iSnipsterCore

/// 一次编辑会话的内存模型。
///
/// 这里只保存原图和轻量矢量操作，不为每次撤销复制整张 Retina 位图。
/// 会话窗口关闭后，原图与撤销栈一起释放，不会写入应用容器。
///
/// Java 对照：它相当于一个由 UI 线程管理的可观察 Aggregate。`final class` 是引用类型，
/// `@Observable` 让 SwiftUI 精确追踪属性读取，`public private(set)` 暴露只读集合。
@MainActor
@Observable
public final class ImageDocument: Identifiable {
    public let id: UUID
    public private(set) var original: RasterImage
    public private(set) var operations: [ImageEditOperation] = []
    /// 快照共享不可变 CGImage；Array 使用 copy-on-write，不会在每一笔复制整张位图。
    /// 与 Vue 状态历史类似，撤销的单位是“文档状态”，因此翻译和清空也能统一撤销。
    private var undoStates: [ImageDocumentSnapshot] = []
    private var redoStates: [ImageDocumentSnapshot] = []
    public var canUndo: Bool { !undoStates.isEmpty }
    public var canRedo: Bool { !redoStates.isEmpty }
    /// 当前工具属于每次截图的瞬时交互状态，仍固定从矩形开始，不跨重启恢复。
    public var selectedTool: EditorTool = .rectangle

    /// 颜色和线宽都按工具独立记忆，切换时恢复该工具上一次的设置。
    private var perToolStrokeColor: [EditorTool: RGBAColor]
    private var perToolStrokeWidth: [EditorTool: CGFloat]

    /// Document 不认识 UserDefaults，只在配置变化时上报新的不可变快照。
    /// `@ObservationIgnored` 表示这个回调不是界面状态，SwiftUI 无需跟踪它。
    @ObservationIgnored
    private let onPreferencesChanged: @MainActor (EditorPreferences) -> Void

    /// 预览与提交操作统一读取当前工具的颜色和线宽。
    // 这是可读写计算属性，没有独立存储；get 组装当前工具样式，set 把新值拆回对应字典。
    public var strokeStyle: StrokeStyle {
        get {
            StrokeStyle(
                color: strokeColor(for: selectedTool),
                width: perToolStrokeWidth[selectedTool] ?? StrokeStyle().width
            )
        }
        set {
            let opaqueColor = Self.opaque(newValue.color)
            let currentWidth = perToolStrokeWidth[selectedTool] ?? StrokeStyle().width
            guard strokeColor(for: selectedTool) != opaqueColor || currentWidth != newValue.width else { return }
            perToolStrokeColor[selectedTool] = opaqueColor
            perToolStrokeWidth[selectedTool] = newValue.width
            publishPreferences()
        }
    }

    public var shapeIsFilled: Bool {
        didSet {
            guard oldValue != shapeIsFilled else { return }
            publishPreferences()
        }
    }

    public var annotationShape: AnnotationShape {
        didSet {
            guard oldValue != annotationShape else { return }
            publishPreferences()
        }
    }

    /// 箭头按钮默认保持 iShot 风格实心箭头；副工具栏可临时切换成普通直线。
    public var arrowMode: ArrowMode {
        didSet {
            guard oldValue != arrowMode else { return }
            publishPreferences()
        }
    }

    public init(
        id: UUID = UUID(),
        original: RasterImage,
        preferences: EditorPreferences = EditorPreferences(),
        onPreferencesChanged: @escaping @MainActor (EditorPreferences) -> Void = { _ in }
    ) {
        self.id = id
        self.original = original
        perToolStrokeColor = preferences.perToolStrokeColor.mapValues { Self.opaque($0) }
        perToolStrokeWidth = preferences.perToolStrokeWidth
        shapeIsFilled = preferences.shapeIsFilled
        annotationShape = preferences.annotationShape
        arrowMode = preferences.arrowMode
        self.onPreferencesChanged = onPreferencesChanged
    }

    public var imageSize: CGSize {
        CGSize(width: original.pixelWidth, height: original.pixelHeight)
    }

    // 调用入口集中维护撤销不变量；View 不直接 append，类似通过 Pinia action 或聚合方法修改共享状态。
    public func commit(_ operation: ImageEditOperation) {
        // Command 模式：提交时只追加轻量操作，最终导出才真正修改像素。
        recordUndoState()
        operations.append(operation)
    }

    /// 文字拖动期间由视图保存轻量预览位置，只在 mouseUp 时替换一次操作并记录一次撤销。
    @discardableResult
    public func moveText(id: UUID, to origin: CGPoint) -> Bool {
        guard let index = operations.lastIndex(where: { $0.id == id }),
              case let .text(operationID, value, rect, color, fontSize) = operations[index],
              rect.origin != origin else {
            return false
        }

        recordUndoState()
        operations[index] = .text(
            id: operationID,
            value: value,
            rect: CGRect(origin: origin, size: rect.size),
            color: color,
            fontSize: fontSize
        )
        return true
    }

    /// 点击已有打码色块时，把删除也记录为一个可撤销命令。
    /// 返回 false 表示点击位置没有活动色块，调用方可以把它当作普通空白单击忽略。
    @discardableResult
    public func removeRedaction(at point: CGPoint) -> Bool {
        let removedIDs = ImageEditOperation.removedRedactionIDs(in: operations)
        guard let targetID = ImageEditOperation.topmostRedactionID(
            at: point,
            in: operations,
            excluding: removedIDs
        ) else {
            return false
        }

        commit(.removeRedaction(id: UUID(), targetID: targetID))
        return true
    }

    /// 当前状态压入重做栈，再恢复上一份状态；等价于两个栈之间移动游标。
    public func undo() {
        guard let previous = undoStates.popLast() else { return }
        redoStates.append(snapshot())
        restore(previous)
    }

    // 重做把刚撤销的快照拿回来，同时将当前状态压回 undo；有新编辑时 redo 会失效。
    public func redo() {
        guard let next = redoStates.popLast() else { return }
        undoStates.append(snapshot())
        restore(next)
    }

    private func restore(_ state: ImageDocumentSnapshot) {
        original = state.original
        operations = state.operations
    }

    /// 新操作产生分叉后清空 redo；最多保留 100 步，并限制旧基底图为 3 张。
    /// 普通画笔只共享一张基底，连续翻译才会创建新图；上限避免长会话累积大量 Retina 位图。
    private func recordUndoState() {
        undoStates.append(snapshot())
        redoStates.removeAll(keepingCapacity: false)
        if undoStates.count > 100 { undoStates.removeFirst(undoStates.count - 100) }
        // ObjectIdentifier 比较引用对象身份，而不是像素是否相同；多个快照共享同一 CGImage 时只占一个身份。
        var images: Set<ObjectIdentifier> = []
        for index in undoStates.indices.reversed() {
            images.insert(ObjectIdentifier(undoStates[index].original.cgImage))
            if images.count > 3 {
                undoStates.removeFirst(index + 1)
                break
            }
        }
    }

    public func strokeColor(for tool: EditorTool) -> RGBAColor {
        perToolStrokeColor[tool] ?? (tool == .redaction ? .redactionDefault : .red)
    }

    public func setStrokeColor(_ color: RGBAColor) {
        // 产品已经移除“标注透明度”，因此在领域模型这一层固定 alpha=1。
        // Java 对照：这相当于在 Aggregate 的 setter 中维护业务不变量，不能只依赖
        // SwiftUI 隐藏滑块，否则未来其他调用方仍可能写入半透明颜色。
        let opaqueColor = Self.opaque(color)
        guard strokeColor(for: selectedTool) != opaqueColor else { return }
        perToolStrokeColor[selectedTool] = opaqueColor
        publishPreferences()
    }

    public func setStrokeWidth(_ width: CGFloat) {
        guard perToolStrokeWidth[selectedTool] != width else { return }
        perToolStrokeWidth[selectedTool] = width
        publishPreferences()
    }

    /// 将当前可持久化配置组装成 DTO 并交给外层存储。
    /// 注意这里刻意不读取 original、operations、undoStates、redoStates，保证用户内容不会落盘。
    private func publishPreferences() {
        onPreferencesChanged(
            EditorPreferences(
                perToolStrokeColor: perToolStrokeColor,
                perToolStrokeWidth: perToolStrokeWidth,
                shapeIsFilled: shapeIsFilled,
                annotationShape: annotationShape,
                arrowMode: arrowMode
            )
        )
    }

    /// 所有入口统一丢弃透明度，防止从旧配置或未来调用方重新引入半透明标注。
    private static func opaque(_ color: RGBAColor) -> RGBAColor {
        RGBAColor(red: color.red, green: color.green, blue: color.blue, alpha: 1)
    }

    /// 翻译会展平标注，但替换前保留完整状态。撤销后仍能继续逐笔撤销旧标注。
    /// 选区调整发生在正式编辑之前，不属于用户编辑历史，由调用方显式关闭记录。
    public func replaceOriginal(with image: RasterImage, recordingUndo: Bool = true) {
        if recordingUndo {
            recordUndoState()
        } else {
            undoStates.removeAll(keepingCapacity: false)
            redoStates.removeAll(keepingCapacity: false)
        }
        original = image
        operations.removeAll(keepingCapacity: false)
    }

    /// 步骤编号从当前有效操作推导，不额外维护容易与 undo/redo 失步的计数器。
    public var nextStepNumber: Int {
        let maximum = operations.reduce(0) { current, operation in
            guard case let .step(_, number, _, _, _) = operation else { return current }
            return max(current, number)
        }
        return maximum + 1
    }
}

/// 定义把不可变编辑快照渲染为最终位图的能力。
public protocol ImageRendering: Sendable {
    func render(document: ImageDocumentSnapshot) async throws -> RasterImage
}

/// 把 MainActor 管理的可变文档转换为可跨 actor 传递的不可变快照。
/// Java 对照：类似在 UI 线程上生成不可变 DTO，再交给线程池执行耗时渲染。
public struct ImageDocumentSnapshot: Sendable {
    public let original: RasterImage
    public let operations: [ImageEditOperation]

    public init(original: RasterImage, operations: [ImageEditOperation]) {
        self.original = original
        self.operations = operations
    }
}

// extension 可以在不继承、不修改原类型声明结构的情况下增加方法，类似 Kotlin extension，
// 此处给具体 final class 添加便利方法；协议扩展的派发规则还取决于方法是否为协议要求。
public extension ImageDocument {
    func snapshot() -> ImageDocumentSnapshot {
        ImageDocumentSnapshot(original: original, operations: operations)
    }
}
