import MacShared
import MacPreferences
import MacTranslation
// 阅读路线
// 给翻译源 enum 补充界面图标与展示信息；联网实现仍在 TextTranslationFeature。
// 领域枚举不需要 import SwiftUI，平台层通过 extension 增加只服务于界面的属性。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import TextTranslationFeature
import iSnipsterCore

/// 将领域枚举转换为 SwiftUI 所需的显示资料。领域层只描述“哪个翻译源”，不依赖 SF Symbols 或文案；
/// 这与 Java Web 中在 Controller/ViewModel 里把 DTO 转成页面展示字段的分层相同。
extension TextTranslationProvider {
    var title: String {
        switch self {
        case .youdao: AppText.text("有道")
        case .apple: "Apple"
        case .google: "Google"
        case .deepL: "DeepL"
        }
    }

    var systemImage: String {
        switch self {
        case .youdao: "character.book.closed"
        case .apple: "apple.logo"
        case .google: "g.circle"
        case .deepL: "d.circle"
        }
    }
}
