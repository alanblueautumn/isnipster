// 阅读路线
// patterns 分别处理手机、固话、客服号、掩码号和国际格式，再补字段上下文匹配。
// 前后断言用于约束数字边界，避免从更长编号中截取一段恰好像电话号码的子串。
// 官方参考（NSRegularExpression 与 UTF-16 范围）：https://developer.apple.com/documentation/foundation/nsregularexpression

import Foundation

/// 手机、固话、客服号和国际号码的纯规则识别器。它只返回字符串位置而不决定如何打码，
/// 因而可被 OCR 自动打码和文本检测共同复用，类似 Java 中无状态的校验工具类。
public enum PhoneNumberRule {
    private static let labels: Set<String> = [
        "电话", "手机", "手机号", "手机号码", "联系电话", "联系方式", "收件电话", "座机",
        "tel", "phone", "mobile", "cellphone", "telephone"
    ]
    private static let patterns = [
        #"(?<![0-9A-Za-z])(?<![0-9][ -])(?:\+?86[ -]?)?1[3-9][0-9][ -]?[0-9]{4}[ -]?[0-9]{4}(?![0-9]|[ -][0-9])"#,
        #"(?<![0-9A-Za-z])(?:\(0[0-9]{2,3}\)|0[0-9]{2,3})[ -]?[0-9]{7,8}(?:[ -]*(?:转|分机|ext\.?)[ -]*[0-9]{1,6})?(?![0-9])"#,
        #"(?<![0-9A-Za-z])(?:400|800)[ -]?[0-9]{3}[ -]?[0-9]{4}(?![0-9]|[ -][0-9])"#,
        #"(?<![0-9A-Za-z])(?:\+?86[ -]?)?1[3-9][0-9][ -]?[*xX•●·]{4}[ -]?[0-9]{4}(?![0-9])"#,
        #"(?<![0-9A-Za-z])\+[1-9][0-9]{0,2}[ -](?:\([0-9]{1,4}\)|[0-9]{1,4})(?:[ -][0-9]{2,4}){2,3}(?![0-9]|[ -][0-9])"#
    ]

    public static func ranges(in text: String) -> [NSRange] {
        // 先匹配完整号码，再补“标签: 值”形式；后者必须经过校验，防止普通数字被误判。
        let formatted = patterns.flatMap { SensitiveTextRanges.find($0, in: text) }
        return formatted + SensitiveTextRanges.labeledValues(
            in: text, labels: labels, valuePattern: #"[+0-9(][0-9()+ -]{5,24}[0-9](?![0-9])"#,
            validate: isPlausibleValue
        )
    }

    public static func matches(_ text: String) -> Bool { !ranges(in: text).isEmpty }

    public static func isStandaloneLabel(_ text: String) -> Bool {
        labels.contains(text.lowercased().filter { !$0.isWhitespace && !":：".contains($0) })
    }

    public static func isPlausibleValue(_ text: String) -> Bool {
        // 正则负责候选召回，这里负责业务语义过滤（日期、连续连字符、长度），二者分工降低复杂正则的维护成本。
        let compact = text.filter { !$0.isWhitespace }
        guard compact.allSatisfy({ "0123456789+-()*xX•●·".contains($0) }) else { return false }
        guard compact.range(of: #"^(?:19|20)[0-9]{2}-[0-9]{1,2}-[0-9]{1,2}$"#,
                            options: .regularExpression) == nil else { return false }
        let count = compact.filter(\.isNumber).count
        return (7...15).contains(count) && !compact.contains("--")
    }
}
