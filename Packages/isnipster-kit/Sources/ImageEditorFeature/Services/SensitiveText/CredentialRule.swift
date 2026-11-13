// 阅读路线
// 密码与密钥必须先命中字段标签，再筛选值；isPlausibleValue 不能单独当作密码探测器。
// 标签集合与排除词集合相当于 Java 校验服务中的业务常量，控制误判范围。
// 官方参考（NSRegularExpression 与 UTF-16 范围）：https://developer.apple.com/documentation/foundation/nsregularexpression

import Foundation

/// 密码、验证码和密钥必须有明确字段上下文；不把任意英文短词或随机字符串当密码。
public enum CredentialRule {
    private static let labels: Set<String> = [
        "密码", "登录密码", "登陆密码", "支付密码", "确认密码", "新密码", "旧密码",
        "wifi密码", "无线密码", "口令", "验证码", "短信验证码", "动态验证码", "校验码", "安全码", "密钥", "秘钥", "令牌",
        "password", "passwd", "pwd", "passcode", "pin", "otp", "verificationcode",
        "apikey", "accesskey", "secretkey", "accesstoken", "refreshtoken", "token", "secret"
    ]
    private static let inlinePattern = #"(?i)(?:密码|口令|验证码|校验码|安全码|密钥|秘钥|令牌|\b(?:password|passwd|pwd|passcode|pin|otp|verification[ _-]?code|api[ _-]?key|access[ _-]?key|secret[ _-]?key|access[ _-]?token|refresh[ _-]?token|token|secret)\b)\s*["']?\s*(?:[:：=]\s*|\s+)\S+"#

    public static func matches(_ text: String) -> Bool {
        !ranges(in: text).isEmpty
    }

    public static func ranges(in text: String) -> [NSRange] {
        SensitiveTextRanges.labeledValues(
            in: text, labels: labels, valuePattern: #"[A-Za-z0-9_*•●·!@#$%&+./~-]{4,256}"#,
            validate: isPlausibleValue
        )
    }

    public static func isStandaloneLabel(_ text: String) -> Bool {
        let normalized = text.lowercased().filter {
            !$0.isWhitespace && !":：=_-\"'".contains($0)
        }
        return labels.contains(normalized)
    }

    /// OCR 拆框时供字段布局匹配器筛选相邻值，不作为无上下文的敏感内容判定。
    public static func isPlausibleValue(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        guard (4...256).contains(compact.count), !isStandaloneLabel(text),
              text == compact,
              compact.allSatisfy({ $0.isASCII && !$0.isWhitespace || "*•●·".contains($0) }) else { return false }
        let controls: Set<String> = [
            "显示", "隐藏", "复制", "登录", "发送", "获取验证码", "忘记密码", "修改密码",
            "show", "hide", "copy", "login", "submit", "forgotpassword", "incorrect", "invalid", "required", "enabled", "disabled", "expired", "error", "none", "null", "true", "false"
        ]
        guard !controls.contains(compact.lowercased()) else { return false }
        return compact.contains { $0.isLetter || $0.isNumber || "*•●·".contains($0) }
    }
}
