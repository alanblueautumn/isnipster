// 阅读路线
// 描述服务来源、请求、结果详情、加载状态和历史快照，供远程客户端与 UI 共同使用。
// DTO 保留业务含义，图标与控件表现由平台层扩展；Sendable 用于异步边界传递。
// 官方参考（Swift 结构体与类）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/

import Foundation

/// 文本翻译源。枚举只表达业务身份，不包含图标等 macOS UI 信息。
public enum TextTranslationProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case youdao
    case apple
    case google
    case deepL

    public var id: Self { self }
}

/// 单个翻译源返回的统一业务结果，供展示层和历史记录共同使用。
public struct TextTranslationOutput: Codable, Equatable, Sendable {
    /// 一个带地区标签的音标，例如英式或美式发音。
    public struct Phonetic: Codable, Equatable, Identifiable, Sendable {
        public let label: String
        public let value: String
        // Identifiable 供 SwiftUI 识别列表项；这里用内容生成身份，相同内容会得到相同 ID。
        public var id: String { "\(label)|\(value)" }

        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
    }

    /// 一条可选带词性标签的词典释义。
    public struct Definition: Codable, Equatable, Identifiable, Sendable {
        public let label: String?
        public let meaning: String
        public var id: String { "\(label ?? "")|\(meaning)" }

        public init(label: String?, meaning: String) {
            self.label = label
            self.meaning = meaning
        }
    }

    /// 单词的一种语法词形，例如复数或过去分词。
    public struct WordForm: Codable, Equatable, Identifiable, Sendable {
        public let name: String
        public let value: String
        public var id: String { "\(name)|\(value)" }

        public init(name: String, value: String) {
            self.name = name
            self.value = value
        }
    }

    /// 与查询词相关的常用短语及其多个译义。
    public struct Phrase: Codable, Equatable, Identifiable, Sendable {
        public let text: String
        public let meanings: [String]
        public var id: String { "\(text)|\(meanings.joined(separator: "|"))" }

        public init(text: String, meanings: [String]) {
            self.text = text
            self.meanings = meanings
        }
    }

    /// 翻译结果的结构化词典详情集合。
    public struct Details: Codable, Equatable, Sendable {
        public let phonetics: [Phonetic]
        public let definitions: [Definition]
        public let wordForms: [WordForm]
        public let examTypes: [String]
        public let phrases: [Phrase]

        public static let empty = Self(
            phonetics: [],
            definitions: [],
            wordForms: [],
            examTypes: [],
            phrases: []
        )

        public var isEmpty: Bool {
            phonetics.isEmpty
                && definitions.isEmpty
                && wordForms.isEmpty
                && examTypes.isEmpty
                && phrases.isEmpty
        }

        public init(
            phonetics: [Phonetic],
            definitions: [Definition],
            wordForms: [WordForm],
            examTypes: [String],
            phrases: [Phrase]
        ) {
            self.phonetics = phonetics
            self.definitions = definitions
            self.wordForms = wordForms
            self.examTypes = examTypes
            self.phrases = phrases
        }
    }

    public let primaryText: String
    public let details: Details

    public init(primaryText: String, details: Details) {
        self.primaryText = primaryText
        self.details = details
    }

    public static func plain(_ text: String) -> Self {
        Self(primaryText: text, details: .empty)
    }
}

/// 一次文本翻译请求。语言通常使用 BCP-47 标识；源语言的 auto 是项目约定的自动识别值，由客户端转换。
public struct TextTranslationRequest: Equatable, Sendable {
    public let text: String
    public let sourceLanguage: String
    public let targetLanguage: String

    public init(text: String, sourceLanguage: String, targetLanguage: String) {
        self.text = text
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

/// 文本翻译窗口的单源状态。通过下面的工厂统一构造字段组合，避免 UI 分散拼装加载、成功和失败状态。
public struct TextTranslationResultState: Equatable, Sendable {
    public let output: TextTranslationOutput?
    public let errorMessage: String?
    public let isLoading: Bool
    public let isIdle: Bool

    public static let idle = Self(
        output: nil,
        errorMessage: nil,
        isLoading: false,
        isIdle: true
    )
    public static let loading = Self(
        output: nil,
        errorMessage: nil,
        isLoading: true,
        isIdle: false
    )

    public static func success(_ output: TextTranslationOutput) -> Self {
        Self(output: output, errorMessage: nil, isLoading: false, isIdle: false)
    }

    public static func failure(_ message: String) -> Self {
        Self(output: nil, errorMessage: message, isLoading: false, isIdle: false)
    }
}

/// 仅在当前应用运行期间保留的一条文本翻译历史。Codable 提供编解码能力，本身不会自动保存到磁盘。
public struct TextTranslationHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let sourceText: String
    public let targetLanguage: String
    public let results: [TextTranslationProvider: TextTranslationOutput]

    public init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        sourceText: String,
        targetLanguage: String,
        results: [TextTranslationProvider: TextTranslationOutput]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.sourceText = sourceText
        self.targetLanguage = targetLanguage
        self.results = results
    }
}
