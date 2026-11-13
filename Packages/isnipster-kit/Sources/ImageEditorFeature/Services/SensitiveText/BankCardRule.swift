// 阅读路线
// 普通数字串先筛位数/前缀再做 Luhn；掩码卡号和明确字段采用各自规则。
// 通过校验只说明符合本项目的候选条件，不验证账号真实存在或属于某家银行。
// 官方参考（NSRegularExpression 与 UTF-16 范围）：https://developer.apple.com/documentation/foundation/nsregularexpression

import Foundation

public enum BankCardRule {
    private static let labels: Set<String> = [
        "卡号", "银行卡", "银行卡号", "银行账号", "银行帐号", "收款账号", "收款帐号", "信用卡号",
        "card number", "cardnumber", "bank account", "bankaccount", "account number"
    ]

    public static func ranges(in text: String) -> [NSRange] {
        // 先取完整数字串再校验，不能从更长的订单号中截出一个碰巧通过校验的子串。
        let numbers = SensitiveTextRanges.find(#"(?<![0-9A-Za-z])[0-9]+(?:[ \t-]+[0-9]+)*(?![0-9A-Za-z])"#, in: text)
            .filter { range in
                guard let range = Range(range, in: text) else { return false }
                let digits = text[range].filter(\.isNumber)
                return (13...19).contains(digits.count) && Set(digits).count > 2
                    && "3456".contains(digits.first ?? "0") && passesLuhn(String(digits))
            }
        let masked = SensitiveTextRanges.find(
            #"(?<![0-9A-Za-z])[3-6][0-9]{3,5}[ -]?(?:[*xX•●·][ -]?){4,12}[0-9]{4}(?![0-9A-Za-z])"#, in: text
        )
        let labeled = SensitiveTextRanges.labeledValues(
            in: text, labels: labels, valuePattern: #"[0-9*•●·][0-9*•●·xX \t-]{6,32}[0-9](?![0-9])"#,
            validate: isPlausibleValue
        )
        return numbers + masked + labeled
    }

    public static func matches(_ text: String) -> Bool { !ranges(in: text).isEmpty }

    public static func isStandaloneLabel(_ text: String) -> Bool {
        let normalized = text.lowercased().filter { !$0.isWhitespace && !":：".contains($0) }
        return labels.contains { $0.filter { !$0.isWhitespace } == normalized }
    }

    /// 明确的银行卡字段允许非 Luhn 的银行账号；普通正文仍须通过校验。
    public static func isPlausibleValue(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace && $0 != "-" }
        guard compact.allSatisfy({ "0123456789*xX•●·".contains($0) }),
              (12...23).contains(compact.count) else { return false }
        return compact.filter(\.isNumber).count >= 4 && Set(compact).count > 2
    }

    // 从右往左，个位不翻倍，隔一位乘 2；两位数减 9 等价于相加其十位和个位，最终总和应能被 10 整除。
    private static func passesLuhn(_ digits: String) -> Bool {
        let sum = digits.reversed().enumerated().reduce(0) { sum, item in
            let digit = item.element.wholeNumberValue ?? 0
            let value = item.offset.isMultiple(of: 2) ? digit : digit * 2
            return sum + (value > 9 ? value - 9 : value)
        }
        return sum.isMultiple(of: 10)
    }
}
