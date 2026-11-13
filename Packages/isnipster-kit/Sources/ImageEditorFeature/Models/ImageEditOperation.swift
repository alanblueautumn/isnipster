// 阅读路线
// RGBAColor/StrokeStyle 描述样式，ImageEditOperation 描述一笔操作，ArrowGeometry 提供共享几何。
// 预览与导出都重放这些数据；enum 的 batch 包含子命令，使一次智能打码只占一个撤销步骤。
// 官方参考（带关联值的枚举）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/enumerations/

import CoreGraphics
import Foundation

/// 纯值对象。`Equatable` 由编译器合成 equals，`Sendable` 声明可安全跨并发域复制。
public struct RGBAColor: Codable, Sendable, Equatable {
    public let red: CGFloat
    public let green: CGFloat
    public let blue: CGFloat
    public let alpha: CGFloat

    public init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = RGBAColor(red: 1, green: 0, blue: 0)
    public static let redactionDefault = RGBAColor(red: 0.00, green: 0.48, blue: 1.00)
}

public struct StrokeStyle: Sendable, Equatable {
    public let color: RGBAColor
    public let width: CGFloat

    public init(color: RGBAColor = .red, width: CGFloat = 4) {
        self.color = color
        self.width = width
    }
}

/// 矩形工具可生成的几何形状。
///
/// Java 对照：这是一个只表达有限业务状态的 enum。把形状作为编辑命令的数据，
/// 预览层和最终导出层就会读取同一个值，避免两套渲染逻辑出现不一致。
// String 指原始值类型，Codable/Sendable/Equatable 是协议；不写显式值时，case 名用作原始字符串。
public enum AnnotationShape: String, Codable, Sendable, Equatable {
    case rectangle
    case ellipse
}

/// 箭头按钮对应两种互斥模式：默认绘制实心箭头，副工具栏勾选“直线”后绘制普通线段。
public enum ArrowMode: String, Codable, Sendable, Equatable {
    case arrow
    case line
}

/// iShot 风格箭头的纯几何计算，预览和最终导出共用同一组顶点。
/// 参考形状是“单尖尾 + 渐宽箭身 + 三角箭头”，这里只计算坐标，不依赖 UI 框架。
public enum ArrowGeometry {
    public static func polygon(from start: CGPoint, to end: CGPoint, width: CGFloat) -> [CGPoint] {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let distance = hypot(deltaX, deltaY)
        guard distance >= 1 else { return [] }

        // 归一化方向向量决定箭头朝向；(-y, x) 得到垂直向量，左右偏移因此适用于任意角度。
        let unitX = deltaX / distance
        let unitY = deltaY / distance
        let perpendicularX = -unitY
        let perpendicularY = unitX

        // 箭头头部沿前进方向的长度。
        // 正常情况下取线宽的 6.5 倍；短箭头最多占总长度的 38%，避免三角头部显得过长。
        // 想让头部更长可以增大 6.5，想改变短箭头的长度上限可以调整 0.38。
        let headLength = min(width * 6.5, distance * 0.38)

        // 箭头头部的“半宽”，即中心线到单侧箭翼的距离；完整头宽是该值的 2 倍。
        // 正常情况下取线宽的 4 倍，同时限制为箭头总长度的 34%，避免短箭头过宽。
        // 想让箭头头部更宽，优先增大 4.0。
        let headHalfWidth = min(width * 4.0, distance * 0.34)

        // 箭身与箭头头部连接位置的“半宽”，完整箭身宽度同样是该值的 2 倍。
        // 它最多取线宽的 1.5 倍，并且不能超过头部半宽的 55%，以保持“箭身窄、箭头宽”。
        // 想让箭身更粗可以增大 1.5；想缩小箭身和箭头的宽度差可以增大 0.55。
        let neckHalfWidth = min(width * 1.5, headHalfWidth * 0.55)
        // 箭翼最外侧两个角所在的基准点。它距离箭尖一个完整的 headLength，
        // 因此负责确定箭头三角部分最靠后的边界。
        let wingBase = CGPoint(
            x: end.x - unitX * headLength,
            y: end.y - unitY * headLength
        )

        // 后掠深度：把箭身连接点从箭翼基准点向箭尖方向推进 headLength 的 25%。
        // 箭翼外角仍留在后方，于是两侧轮廓会像飞机机翼一样向箭尾后掠。
        // 增大 0.25 会让后掠更明显；减小它则更接近普通三角箭头。
        let sweepDepth = headLength * 0.25
        let neckBase = CGPoint(
            x: wingBase.x + unitX * sweepDepth,
            y: wingBase.y + unitY * sweepDepth
        )

        func offset(_ point: CGPoint, by amount: CGFloat) -> CGPoint {
            CGPoint(
                x: point.x + perpendicularX * amount,
                y: point.y + perpendicularY * amount
            )
        }

        return [
            // 起点只使用一个顶点，箭身两侧从这里分别延伸到颈部，形成参考图中的尖尾。
            start,
            // 颈部位于箭翼角前方；从颈部折回箭翼角，形成左右对称的后掠缺口。
            offset(neckBase, by: neckHalfWidth),
            offset(wingBase, by: headHalfWidth),
            end,
            offset(wingBase, by: -headHalfWidth),
            offset(neckBase, by: -neckHalfWidth)
        ]
    }
}

/// 所有几何坐标均使用原始图片的像素坐标，原点在左上角。
/// 这样窗口缩放只影响 View 到图片的坐标映射，不会修改编辑数据本身。
///
/// 每个 case 可以拥有不同字段，这是 Swift 枚举比 Java enum 更重要的能力。
/// 它很适合表达封闭的命令集合，switch 会在新增工具但漏处理时给出编译错误。
public enum ImageEditOperation: Sendable, Equatable, Identifiable {
    case shape(
        id: UUID,
        rect: CGRect,
        style: StrokeStyle,
        isFilled: Bool,
        shape: AnnotationShape
    )
    case arrow(
        id: UUID,
        start: CGPoint,
        end: CGPoint,
        style: StrokeStyle,
        mode: ArrowMode
    )
    case freehand(id: UUID, points: [CGPoint], style: StrokeStyle)
    case text(id: UUID, value: String, rect: CGRect, color: RGBAColor, fontSize: CGFloat)
    /// 智能打码生成的不透明色块。颜色作为命令数据保存，保证画布预览与最终导出一致。
    case redaction(id: UUID, rect: CGRect, color: RGBAColor)
    /// 点击已有色块时不直接篡改历史，而是追加一条“隐藏指定色块”的命令。
    /// 因此普通 undo/redo 仍然可以恢复或再次取消这个色块。
    case removeRedaction(id: UUID, targetID: UUID)
    case step(id: UUID, number: Int, center: CGPoint, diameter: CGFloat, color: RGBAColor)
    /// 把一组操作合并为一次可撤销的原子提交。智能打码会一次性生成多个遮挡色块，
    /// 用 batch 包裹后一次 undo 即可整体撤销，而不是逐块撤销。
    // Array 保存子命令，形成递归树；批量命令的 id 标识整次提交，各子操作仍保留自己的 id。
    case batch(id: UUID, operations: [ImageEditOperation])

    public var id: UUID {
        // 多个 case 可以合并匹配，并只取我们关心的 id；下划线表示忽略其他关联值。
        switch self {
        case let .shape(id, _, _, _, _),
             let .arrow(id, _, _, _, _),
             let .freehand(id, _, _),
             let .text(id, _, _, _, _),
             let .redaction(id, _, _),
             let .removeRedaction(id, _),
             let .step(id, _, _, _, _),
             let .batch(id, _):
            return id
        }
    }
}

public extension ImageEditOperation {
    /// 先汇总所有取消命令，再由预览层和导出层共同跳过对应色块。
    /// Java 对照：这相当于从 command list 构建一个只读的 cancelledIds 索引。
    static func removedRedactionIDs(in operations: [ImageEditOperation]) -> Set<UUID> {
        var result = Set<UUID>()

        func collect(_ operation: ImageEditOperation) {
            switch operation {
            case let .removeRedaction(_, targetID):
                result.insert(targetID)
            case let .batch(_, children):
                children.forEach(collect)
            default:
                break
            }
        }

        operations.forEach(collect)
        return result
    }

    /// 从后向前命中，重叠色块时优先删除视觉上位于最上层的那一块。
    static func topmostRedactionID(
        at point: CGPoint,
        in operations: [ImageEditOperation],
        excluding removedIDs: Set<UUID>
    ) -> UUID? {
        for operation in operations.reversed() {
            switch operation {
            case let .redaction(id, rect, _):
                if !removedIDs.contains(id), rect.contains(point) {
                    return id
                }
            case let .batch(_, children):
                if let id = topmostRedactionID(
                    at: point,
                    in: children,
                    excluding: removedIDs
                ) {
                    return id
                }
            default:
                break
            }
        }
        return nil
    }
}

/// 只包含需要在画布上交互的工具。OCR/翻译是点击即执行的异步命令，不混入这里。
/// 取色器也属于画布工具：选中后下一次点击读取冻结截图中的一个像素。
public enum EditorTool: String, Codable, Sendable, Identifiable {
    case rectangle
    case arrow
    case pen
    /// 自动识别完成后仍保持为当前工具，用户可继续拖动补充实心遮挡区域。
    case redaction
    case text
    case step
    case colorPicker

    public var id: String { rawValue }
}
