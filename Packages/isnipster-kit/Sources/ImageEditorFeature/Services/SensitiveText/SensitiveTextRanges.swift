// 阅读路线
// 规则共用的三个步骤：find 取范围、labeledValues 校验字段值、merge 合并遮盖区间。
// NSRange 是 UTF-16 位置；Swift 字符串按 Character 遍历，转换时始终保留原始 String。
// 官方参考（NSRegularExpression 与 UTF-16 范围）：https://developer.apple.com/documentation/foundation/nsregularexpression

import Foundation

/// 所有范围均指向原始 OCR 字符串，不先删空格或转换全角字符，以免位置漂移。
enum SensitiveTextRanges {
    // NSRegularExpression 类似 Java Pattern/Matcher；group=0 是整段匹配，group=1 是第一个捕获组。
    static func find(_ pattern: String, in text: String, group: Int = 0) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
            .map { $0.range(at: group) }.filter { $0.location != NSNotFound && $0.length > 0 }
    }

    static func labeledValues(in text: String, labels: Set<String>, valuePattern: String,
                              validate: (String) -> Bool) -> [NSRange] {
        // 先按标签长度降序，避免短标签抢先匹配；escapedPattern 把标签当字面文本，而不是正则语法。
        let alternatives = labels.sorted { $0.count > $1.count }
            .map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "(?i)(?<![a-zA-Z])(?:" + alternatives + ")[ \\t]*[:：=][ \\t]*(" + valuePattern + ")"
        return find(pattern, in: text, group: 1).filter { range in
            guard let range = Range(range, in: text) else { return false }
            return validate(String(text[range]))
        }
    }

    // 先排序再合并重叠或相邻区间；保存的仍是原文 UTF-16 位置，便于后面映射到 OCR 字符框。
    static func merge(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }
}
