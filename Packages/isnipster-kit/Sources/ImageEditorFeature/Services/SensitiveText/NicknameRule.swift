// 阅读路线
// 昵称来自 @提及、时间戳后的姓名或明确标签；普通正文中的名字不直接判定为敏感项。
// controls 排除常见按钮与状态词，避免把“发送”“在线”等 UI 文案当成用户名。
// 官方参考（NSRegularExpression 与 UTF-16 范围）：https://developer.apple.com/documentation/foundation/nsregularexpression

import Foundation

public enum NicknameRule {
    private static let labels: Set<String> = [
        "昵称", "名字", "姓名", "用户名", "收件人", "联系人", "username", "nickname"
    ]
    private static let controls: Set<String> = [
        "发送", "取消", "确定", "搜索", "更多", "回复", "转发", "删除", "撤回", "编辑", "设置",
        "在线", "离线", "正在输入", "昨天", "今天", "星期一", "星期二", "星期三", "星期四", "星期五",
        "文件传输助手", "公众号", "服务号", "订阅号", "微信支付", "微信团队",
        "send", "cancel", "search", "reply", "delete", "more", "online", "offline", "today", "yesterday"
    ]

    public static func ranges(in text: String) -> [NSRange] {
        // 正文中的普通“姓名/昵称”字样不构成敏感值；@ 只匹配独立的用户名。
        let mentions = SensitiveTextRanges.find(
            #"(?<![\p{L}\p{N}._%+-])@[\p{L}\p{N}_-]{1,32}(?![\p{L}\p{N}_.-])"#, in: text
        )
        let transcriptNames = SensitiveTextRanges.find(
            #"(?m)^[ \t]*\[?[0-9]{4}[-/][0-9]{1,2}[-/][0-9]{1,2}[ T](?:[01]?[0-9]|2[0-3]):[0-5][0-9](?::[0-5][0-9])?\]?[ \t]+([\p{L}\p{N}_·.-]{1,32})[ \t]*[:：]"#,
            in: text, group: 1
        )
        return mentions + transcriptNames + SensitiveTextRanges.labeledValues(
            in: text, labels: labels, valuePattern: #"[\p{L}\p{N}_·.-]{1,32}(?![\p{L}\p{N}_·.-])"#,
            validate: isPlausibleValue
        )
    }

    public static func matches(_ text: String) -> Bool { !ranges(in: text).isEmpty }

    public static func isStandaloneLabel(_ text: String) -> Bool {
        let value = text.lowercased().filter { !$0.isWhitespace && !":：".contains($0) }
        return labels.contains(value)
    }

    public static func isPlausibleValue(_ text: String) -> Bool {
        let compact = text.filter { !$0.isWhitespace }
        guard (1...32).contains(compact.count), !isStandaloneLabel(text),
              !controls.contains(compact.lowercased()),
              !compact.contains(where: { "。！？!?；;:：，,".contains($0) }),
              !["请输入", "修改昵称", "设置昵称", "查看", "点击", "输入姓名", "不知道"].contains(where: compact.contains) else { return false }
        return compact.contains { $0.isLetter }
    }
}
