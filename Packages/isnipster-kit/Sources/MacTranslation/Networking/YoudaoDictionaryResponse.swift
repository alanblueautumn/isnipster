import MacShared
// 阅读路线
// 把有道嵌套响应收敛为统一的词义、发音、词形、考试标签和短语结构。
// 解码类型只声明需要的字段；Optional 表达接口可能省略的数据，展示层不需要接触原始 JSON。
// 官方参考（Decodable）：https://developer.apple.com/documentation/swift/decodable

import Foundation
import TextTranslationFeature

/// 有道网页词典的精简响应模型，只保留文本翻译窗口实际展示的字段。
struct YoudaoDictionaryResponse: Decodable {
    // 自动合成的 Decodable 忽略未声明的 JSON 字段；Optional 允许缺失或 null，类型不匹配仍会抛错。
    /// 有道英汉或汉英词典区域。
    struct DictionarySection: Decodable {
        let examTypes: [String]?
        let word: Word?

        // 类似 Jackson 的 @JsonProperty：把服务字段名映射到 Swift 属性名。
        enum CodingKeys: String, CodingKey {
            case examTypes = "exam_type"
            case word
        }
    }

    /// 单词级详情，包括音标、释义和词形。
    struct Word: Decodable {
        /// 一条带词性的词典释义。
        struct Translation: Decodable {
            let partOfSpeech: String?
            let translation: String?
            let text: String?
            let alternateTranslation: String?

            enum CodingKeys: String, CodingKey {
                case partOfSpeech = "pos"
                case translation = "tran"
                case text = "#text"
                case alternateTranslation = "#tran"
            }
        }

        /// 有道响应中包裹词形数据的容器。
        struct WordFormContainer: Decodable {
            /// 一个词形名称及其对应值。
            struct WordForm: Decodable {
                let name: String?
                let value: String?
            }

            let wordForm: WordForm?

            enum CodingKeys: String, CodingKey {
                case wordForm = "wf"
            }
        }

        let usPhonetic: String?
        let ukPhonetic: String?
        let phonetic: String?
        let translations: [Translation]?
        let wordForms: [WordFormContainer]?

        enum CodingKeys: String, CodingKey {
            case usPhonetic = "usphone"
            case ukPhonetic = "ukphone"
            case phonetic = "phone"
            case translations = "trs"
            case wordForms = "wfs"
        }
    }

    /// 有道网络释义区域。
    struct WebSection: Decodable {
        /// 一条网络短语及其译义列表。
        struct Entry: Decodable {
            /// 网络短语的一条译义。
            struct Meaning: Decodable {
                let value: String?
            }

            let key: String?
            let translations: [Meaning]?

            enum CodingKeys: String, CodingKey {
                case key
                case translations = "trans"
            }
        }

        let entries: [Entry]?

        enum CodingKeys: String, CodingKey {
            case entries = "web-translation"
        }
    }

    let englishChinese: DictionarySection?
    let chineseEnglish: DictionarySection?
    let web: WebSection?

    enum CodingKeys: String, CodingKey {
        case englishChinese = "ec"
        case chineseEnglish = "ce"
        case web = "web_trans"
    }

    /// 优先取英汉区域，缺失时取汉英区域；把服务专属结构转换成 UI 共用的 DTO。
    func details(query: String) -> TextTranslationOutput.Details {
        let section = englishChinese ?? chineseEnglish
        let word = section?.word
        let details = TextTranslationOutput.Details(
            phonetics: phonetics(from: word),
            definitions: definitions(from: word),
            wordForms: wordForms(from: word),
            examTypes: section?.examTypes ?? [],
            phrases: phrases(query: query)
        )
        return details
    }

    private func phonetics(from word: Word?) -> [TextTranslationOutput.Phonetic] {
        var values: [TextTranslationOutput.Phonetic] = []
        if let phonetic = word?.phonetic, !phonetic.isEmpty {
            values.append(.init(label: "拼音", value: phonetic))
        }
        if let usPhonetic = word?.usPhonetic, !usPhonetic.isEmpty {
            values.append(.init(label: "美", value: usPhonetic))
        }
        if let ukPhonetic = word?.ukPhonetic, !ukPhonetic.isEmpty {
            values.append(.init(label: "英", value: ukPhonetic))
        }
        return values
    }

    // 先取前 6 条，再丢弃无释义项，因此最终可能少于 6 条；每条按 Swift Character 截短。
    private func definitions(from word: Word?) -> [TextTranslationOutput.Definition] {
        (word?.translations ?? [])
            .prefix(6)
            .compactMap { item in
                guard let meaning = item.translation ?? item.alternateTranslation,
                      !meaning.isEmpty else {
                    return nil
                }
                let shortened = meaning.count > 240
                    ? String(meaning.prefix(240)) + "…"
                    : meaning
                return TextTranslationOutput.Definition(
                    label: item.partOfSpeech ?? item.text,
                    meaning: shortened
                )
            }
    }

    // compactMap 类似 map 后过滤 null；闭包返回 nil 就跳过缺字段或空内容的词形。
    private func wordForms(from word: Word?) -> [TextTranslationOutput.WordForm] {
        (word?.wordForms ?? []).compactMap { container in
            guard let form = container.wordForm,
                  let name = form.name,
                  let value = form.value,
                  !name.isEmpty,
                  !value.isEmpty else {
                return nil
            }
            return TextTranslationOutput.WordForm(name: name, value: value)
        }
    }

    // 忽略大小写排除查询词本身；最多取 3 个候选短语，每个保留最多 3 条非空译义。
    private func phrases(query: String) -> [TextTranslationOutput.Phrase] {
        (web?.entries ?? [])
            .filter { entry in
                guard let key = entry.key else { return false }
                return key.caseInsensitiveCompare(query) != .orderedSame
            }
            .prefix(3)
            .compactMap { entry in
                guard let key = entry.key, !key.isEmpty else { return nil }
                let meanings = (entry.translations ?? [])
                    .compactMap(\.value)
                    .filter { !$0.isEmpty }
                    .prefix(3)
                guard !meanings.isEmpty else { return nil }
                return TextTranslationOutput.Phrase(
                    text: key,
                    meanings: Array(meanings)
                )
            }
    }
}
