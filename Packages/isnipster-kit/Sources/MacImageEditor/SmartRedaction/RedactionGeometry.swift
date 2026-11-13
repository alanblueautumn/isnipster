import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 归一化框 ↔ 像素框，并按覆盖比例去除重复内部框；这里保持 Vision 的左下原点。
// 要比较实际形状，应先乘图片宽高；0...1 空间中的正方形在宽屏图片上并不一定是正方形。
// 官方参考（Vision 文字与区域）：https://developer.apple.com/documentation/vision/vnrecognizedtext

import CoreGraphics

/// 智能打码内部几何约定：归一化坐标和像素坐标都使用左下原点。
/// 只有生成编辑操作时翻转 Y，避免宽屏截图上把归一化的长方形误判成正方形。
enum RedactionGeometry {
    static let unitBounds = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func pixels(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: rect.minX * imageSize.width, y: rect.minY * imageSize.height,
               width: rect.width * imageSize.width, height: rect.height * imageSize.height)
    }

    static func normalized(_ rect: CGRect, imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        return CGRect(x: rect.minX / imageSize.width, y: rect.minY / imageSize.height,
                      width: rect.width / imageSize.width, height: rect.height / imageSize.height)
            .intersection(unitBounds)
    }

    // 计算 inner 被 outer 覆盖的面积比例，不是交并比 IoU；顺序反过来会得到不同结果。
    static func coverage(of inner: CGRect, by outer: CGRect) -> CGFloat {
        guard !inner.isEmpty else { return 0 }
        let overlap = inner.intersection(outer)
        guard !overlap.isNull, !overlap.isEmpty else { return 0 }
        return overlap.width * overlap.height / (inner.width * inner.height)
    }

    /// 同一图形的轮廓和矩形可能重复命中；外框优先，避免生成叠加色块。
    static func uniqueOuterRects(_ rects: [CGRect]) -> [CGRect] {
        let ordered = rects.filter { !$0.isNull && !$0.isEmpty }.sorted {
            $0.width * $0.height > $1.width * $1.height
        }
        var result: [CGRect] = []
        for rect in ordered where !result.contains(where: { coverage(of: rect, by: $0) >= 0.85 }) {
            result.append(rect)
        }
        return result
    }

}
