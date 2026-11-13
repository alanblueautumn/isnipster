// 阅读路线
// 地址命中由直接模式和“标签: 值”两路组成；trimPrefix 去掉寄到、住在等非地址前缀。
// 规则返回原文范围而不是替换文本，这样 OCR 层还能按原位置找到要遮盖的字符。
// 官方参考（NSRegularExpression 与 UTF-16 范围）：https://developer.apple.com/documentation/foundation/nsregularexpression

import Foundation

/// 中英文地址识别规则。地址没有全国统一、可完全验证的格式，所以先用较明确的街道模式，
/// 再结合“标签: 值”补充识别；宁可少量漏检，也要限制把自然语言整句误打码的概率。
public enum AddressRule {
    private static let labels: Set<String> = [
        "地址", "住址", "收货地址", "收件地址", "邮寄地址", "联系地址", "详细地址", "家庭住址",
        "address", "shipping address", "mailing address"
    ]
    private static let street = #"[\p{Han}]{2,16}(?:路|街|巷|弄|大道)[0-9一二三四五六七八九十百-]{1,8}号(?:[\p{Han}A-Za-z0-9-]{0,12}(?:栋|幢|单元|室|楼)){0,4}"#
    private static let english = #"(?i)\b[0-9]{1,6}[ \t]+(?:[A-Z0-9.'-]+[ \t]+){1,5}(?:street|st|road|rd|avenue|ave|lane|ln|drive|dr|boulevard|blvd|court|ct)\b\.?(?:[ ,]+(?:apt|unit|suite|ste)[ .#-]*[A-Z0-9-]+)?"#

    public static func ranges(in text: String) -> [NSRange] {
        let chinese = #"(?:[\p{Han}]{2,8}(?:省|自治区))?(?:[\p{Han}]{2,8}市)?(?:[\p{Han}]{2,8}(?:区|县))?"# + street
        let direct = SensitiveTextRanges.find(chinese, in: text).map { trimPrefix($0, in: text) }
            + SensitiveTextRanges.find(english, in: text)
        return direct + SensitiveTextRanges.labeledValues(
            in: text, labels: labels, valuePattern: #"[^，,。;；\n]{6,100}"#,
            validate: isPlausibleValue
        )
    }

    public static func matches(_ text: String) -> Bool { !ranges(in: text).isEmpty }

    public static func isStandaloneLabel(_ text: String) -> Bool {
        let normalized = text.lowercased().filter { !$0.isWhitespace && !":：".contains($0) }
        return labels.contains { $0.filter { !$0.isWhitespace } == normalized }
    }

    public static func isPlausibleValue(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...100).contains(value.count),
              !value.contains(where: { "？?！!。;；:：".contains($0) }),
              !["不知道", "修改", "填写", "请输入", "选择", "复制", "怎么", "什么", "在哪", "没有", "发给", "告诉"].contains(where: value.contains) else { return false }
        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        return SensitiveTextRanges.find(street, in: value).contains(fullRange)
            || SensitiveTextRanges.find(english, in: value).contains(fullRange)
            || value.range(of: #"^[\p{Han}]{2,10}(?:省|市|自治区)[\p{Han}]{2,12}(?:市|区|县|镇)[\p{Han}0-9-]{2,50}$"#, options: .regularExpression) != nil
            || value.range(of: #"^[\p{Han}]{2,16}(?:小区|公寓|花园|大厦)[A-Za-z0-9一二三四五六七八九十-]+(?:栋|幢|单元|室|楼)[\p{Han}A-Za-z0-9-]*$"#, options: .regularExpression) != nil
    }

    private static func trimPrefix(_ range: NSRange, in text: String) -> NSRange {
        // OCR 常把“寄到/地址是”与实际地址连成一个块；去掉语义前缀，让高亮只覆盖敏感值。
        guard let swiftRange = Range(range, in: text) else { return range }
        let value = String(text[swiftRange])
        let prefixes = ["寄到", "送到", "住在", "位于", "地址是", "地址为"]
        let end = prefixes.compactMap { value.range(of: $0)?.upperBound }.max()
        guard let end else { return range }
        let length = value[..<end].utf16.count
        return NSRange(location: range.location + length, length: range.length - length)
    }
}
