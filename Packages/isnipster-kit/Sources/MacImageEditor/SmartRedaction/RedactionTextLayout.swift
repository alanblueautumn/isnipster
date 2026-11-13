import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 保留 OCR 原始下标与像素矩形，供标签和值的空间匹配使用。
// index 是本次识别结果的关联键，不是跨识别会话的稳定身份；confidence 是识别置信度。
// 官方参考（Vision 文字与区域）：https://developer.apple.com/documentation/vision/vnrecognizedtext

import CoreGraphics

/// 已换算到同一张识别图的像素坐标。保留 OCR 下标，便于字段布局规则回写到原始 OCR 框。
struct RedactionTextLayout: Sendable {
    let index: Int
    let text: String
    let rect: CGRect
    let confidence: Float
}
