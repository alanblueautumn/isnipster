import MacShared
import MacPreferences
// 阅读路线
// 统一时间线尺寸与字体缩放；调用方使用逻辑尺寸，集中转换后再交给 SwiftUI。
// 这相当于前端 design token，改一个比例即可保持卡片与控件尺寸协调。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import SwiftUI

/// 集中样式缩放入口：scaled 管尺寸，font 管字体；不要在各卡片里重复乘缩放倍率。
enum ClipboardShelfMetrics {
    static let scale: CGFloat = 1.1

    static func scaled(_ value: CGFloat) -> CGFloat {
        value * scale
    }

    static func font(_ base: Font) -> Font {
        if #available(macOS 26.0, *) {
            base.scaled(by: scale)
        } else {
            base
        }
    }
}
