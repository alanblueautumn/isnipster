// 阅读路线
// 这里汇总各敏感规则的字符串命中，再交给平台层映射为像素矩形。
// 文本规则不操作 UI 或图片；这与 Java 中可复用的领域校验器分层相同。
// 官方参考（Swift 并发与隔离）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import Foundation

/// 纯文本规则只返回原字符串中的敏感范围，OCR 定位和聊天布局由平台层负责。
public enum SensitiveTextDetector {
    public static func ranges(in text: String) -> [NSRange] {
        // 全角 ASCII 与半角一一对应，UTF-16 长度不变，范围仍能回到原 OCR 字符。
        let normalized = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            if (0xFF01...0xFF5E).contains(scalar.value) {
                return UnicodeScalar(scalar.value - 0xFEE0) ?? scalar
            }
            return scalar.value == 0x3000 ? UnicodeScalar(0x20)! : scalar
        }))
        return matchingRanges(in: normalized)
    }

    private static func matchingRanges(in text: String) -> [NSRange] {
        SensitiveTextRanges.merge(
            PhoneNumberRule.ranges(in: text)
                + IdentityNumberRule.ranges(in: text)
                + BankCardRule.ranges(in: text)
                + AddressRule.ranges(in: text)
                + EmailRule.ranges(in: text)
                + CredentialRule.ranges(in: text)
                + NicknameRule.ranges(in: text)
        )
    }

    public static func isSensitive(_ text: String) -> Bool { !ranges(in: text).isEmpty }
}

/// 行内字段和 OCR 拆框字段共用同一组语义规则。
public enum SensitiveFieldKind: CaseIterable, Sendable {
    case phone, bankCard, identity, address, email, credential, nickname

    public func isLabel(_ text: String) -> Bool {
        switch self {
        case .phone: PhoneNumberRule.isStandaloneLabel(text)
        case .bankCard: BankCardRule.isStandaloneLabel(text)
        case .identity: IdentityNumberRule.isStandaloneLabel(text)
        case .address: AddressRule.isStandaloneLabel(text)
        case .email: EmailRule.isStandaloneLabel(text)
        case .credential: CredentialRule.isStandaloneLabel(text)
        case .nickname: NicknameRule.isStandaloneLabel(text)
        }
    }

    public func isValue(_ text: String) -> Bool {
        switch self {
        case .phone: PhoneNumberRule.isPlausibleValue(text)
        case .bankCard: BankCardRule.isPlausibleValue(text)
        case .identity: IdentityNumberRule.isPlausibleValue(text)
        case .address: AddressRule.isPlausibleValue(text)
        case .email: EmailRule.isPlausibleValue(text)
        case .credential: CredentialRule.isPlausibleValue(text)
        case .nickname: NicknameRule.isPlausibleValue(text)
        }
    }
}
