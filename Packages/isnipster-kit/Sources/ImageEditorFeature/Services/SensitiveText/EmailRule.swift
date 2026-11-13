// 阅读路线
// ranges 查找正文中的邮箱，isPlausibleValue 要求整个字段值匹配；二者不要混用。
// 正则采用常见邮箱形式的启发式匹配，并不实现所有合法邮件地址语法。
// 官方参考（NSRegularExpression 与 UTF-16 范围）：https://developer.apple.com/documentation/foundation/nsregularexpression

import Foundation

/// 邮箱识别规则。NSRegularExpression 的 NSRange 以 UTF-16 代码单元计数；
/// Vision 的字符框查询使用 Range<String.Index>，转换必须带上原字符串，不能直接拿整数下标代替。
public enum EmailRule {
    private static let labels: Set<String> = [
        "邮箱", "电子邮箱", "邮件", "电子邮件", "email", "mail"
    ]

    private static let pattern = #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#

    public static func matches(_ text: String) -> Bool {
        !ranges(in: text).isEmpty
    }

    public static func ranges(in text: String) -> [NSRange] {
        SensitiveTextRanges.find(pattern, in: text)
    }

    public static func isStandaloneLabel(_ text: String) -> Bool {
        labels.contains(normalizedLabel(text))
    }

    public static func isPlausibleValue(_ text: String) -> Bool {
        // 要求匹配范围覆盖整个候选值，避免“含一个邮箱的长句”被标签检测当成邮箱值。
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ranges(in: value).contains(NSRange(value.startIndex..<value.endIndex, in: value))
    }

    private static func normalizedLabel(_ text: String) -> String {
        text.lowercased().filter {
            !$0.isWhitespace && !":：=_-\"'".contains($0)
        }
    }
}
