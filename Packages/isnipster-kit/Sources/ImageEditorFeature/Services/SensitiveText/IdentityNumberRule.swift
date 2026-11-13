// 阅读路线
// 候选筛选 → 省级前缀 → 年月日往返校验 → 顺序码 → 加权校验位。
// 每个 guard 都是一个拒绝条件；这验证格式和校验位，不查询身份真实性。
// 官方参考（NSRegularExpression 与 UTF-16 范围）：https://developer.apple.com/documentation/foundation/nsregularexpression

import Foundation

/// 中国居民身份证号码规则：正则只筛出 18 位候选，随后校验行政区、日期和 ISO 7064 校验位。
/// 这是“宽召回 + 严校验”的两阶段设计，优于把全部规则塞进一个不可维护的正则表达式。
public enum IdentityNumberRule {
    private static let provinces: Set<String> = [
        "11", "12", "13", "14", "15", "21", "22", "23", "31", "32", "33", "34", "35", "36", "37",
        "41", "42", "43", "44", "45", "46", "50", "51", "52", "53", "54", "61", "62", "63", "64", "65", "71", "81", "82"
    ]

    public static func ranges(in text: String) -> [NSRange] {
        SensitiveTextRanges.find(#"(?<![0-9A-Za-z])[1-9][0-9]{16}[0-9Xx](?![0-9A-Za-z])"#, in: text)
            .filter {
                guard let range = Range($0, in: text) else { return false }
                return isPlausibleValue(String(text[range]))
            }
    }

    public static func matches(_ text: String) -> Bool { !ranges(in: text).isEmpty }

    public static func isStandaloneLabel(_ text: String) -> Bool {
        let label = text.lowercased().filter { !$0.isWhitespace && !":：".contains($0) }
        return ["身份证", "身份证号", "身份证号码", "公民身份号码", "identitynumber"].contains(label)
    }

    public static func isPlausibleValue(_ text: String) -> Bool {
        // Calendar 可能把越界日期归一化；创建 Date 后再读回年月日逐项比较，才能拒绝 2 月 30 日。
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let characters = Array(value)
        guard characters.count == 18, provinces.contains(String(value.prefix(2))),
              characters.prefix(17).allSatisfy({ "0123456789".contains($0) }),
              let year = Int(String(characters[6..<10])), (1900...2099).contains(year),
              let month = Int(String(characters[10..<12])),
              let day = Int(String(characters[12..<14])),
              String(characters[14..<17]) != "000" else { return false }
        let calendar = Calendar(identifier: .gregorian)
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: parts) else { return false }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else { return false }
        let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
        let checksum = Array("10X98765432")
        let sum = zip(characters.prefix(17), weights).reduce(0) { $0 + ($1.0.wholeNumberValue ?? 0) * $1.1 }
        return characters[17] == checksum[sum % 11]
    }
}
