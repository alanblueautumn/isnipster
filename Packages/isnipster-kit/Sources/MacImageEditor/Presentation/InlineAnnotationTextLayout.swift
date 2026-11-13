import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 用 CoreText 获取每行文字和基线位置，供画布绘制与文字命中共同使用。
// 字符宽度不等于字号，基线也不等于矩形顶部；不能按 String.count 平均分配多行字形位置。
// 官方参考（Core Text 排版）：https://developer.apple.com/documentation/coretext

import CoreText
import Foundation

/// 绘制和命中共用字形位置；排版宽度只控制换行，不作为可拖动范围。
enum InlineAnnotationTextLayout {
    struct Line {
        let text: CTLine
        let baseline: CGPoint
        let visibleBounds: CGRect
    }

    static func lines(_ value: String, in rect: CGRect, fontSize: CGFloat) -> [Line] {
        guard !value.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        // 创建 CoreText 字体供位图排版使用；SwiftUI Font、AppKit NSFont 与 CTFont 属于不同 API 层。
        let font = CTFontCreateWithName("Helvetica Neue Medium" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true
        ]
        let attributed = NSAttributedString(string: value, attributes: attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let source = value as NSString
        let ascent = CTFontGetAscent(font)
        let lineHeight = ceil(ascent + CTFontGetDescent(font) + CTFontGetLeading(font))
        var location = 0
        var top = rect.minY
        var result: [Line] = []

        while location < attributed.length, top < rect.maxY {
            // 按实际字形测量确定当前宽度可容纳的 UTF-16 长度；不能按字符数或字号平均估算换行。
            let length = CTTypesetterSuggestLineBreak(typesetter, location, Double(rect.width))
            guard length > 0 else { break }
            let value = source.substring(with: NSRange(location: location, length: length))
                .trimmingCharacters(in: .newlines)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
            let bounds = CTLineGetImageBounds(line, nil)
            // ascent 是基线以上的高度；本模型顶部向下递增，因此基线位于当前行顶部加 ascent 的位置。
            let baseline = CGPoint(x: rect.minX, y: top + ascent)
            if !bounds.isNull, !bounds.isEmpty {
                result.append(Line(
                    text: line,
                    baseline: baseline,
                    visibleBounds: CGRect(
                        x: baseline.x + bounds.minX,
                        y: baseline.y - bounds.maxY,
                        width: bounds.width,
                        height: bounds.height
                    )
                ))
            }
            location += length
            top += lineHeight
        }
        return result
    }
}
