import Foundation
import NaturalLanguage

enum TextLanguageDetector {
    /// 用于界面提示和自动翻译方向；没有足够语言证据时保持未知。
    static func detect(_ text: String) -> String? {
        guard text.contains(where: \.isLetter) else { return nil }
        // NaturalLanguage 在本机估计文本语言；短文本可能证据不足，返回结果不能视为确定事实。
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let language = recognizer.dominantLanguage,
           language != .undetermined,
           (recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0) >= 0.75 {
            return switch language {
            case .simplifiedChinese: "zh-Hans"
            case .traditionalChinese: "zh-Hant"
            case .english: "en-US"
            case .japanese: "ja-JP"
            case .korean: "ko-KR"
            default: language.rawValue
            }
        }

        // 短词可能达不到置信度门槛；仅对明确的文字特征兜底，避免沿用上次的翻译方向。
        let scalarValues = text.unicodeScalars.map(\.value)
        if scalarValues.contains(where: { (0x3040 ... 0x30FF).contains($0) }) {
            return "ja-JP"
        }
        if scalarValues.contains(where: { (0xAC00 ... 0xD7AF).contains($0) }) {
            return "ko-KR"
        }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        if !letters.isEmpty, letters.allSatisfy({
            (0x41 ... 0x5A).contains($0.value) || (0x61 ... 0x7A).contains($0.value)
        }) {
            // 低置信度且全部字母为 A-Z/a-z 时，按本应用的中英互译默认规则处理。
            return "en-US"
        }
        if !letters.isEmpty, letters.allSatisfy({
            (0x3400 ... 0x4DBF).contains($0.value)
                || (0x4E00 ... 0x9FFF).contains($0.value)
                || (0x20000 ... 0x2FA1F).contains($0.value)
        }) {
            return "zh-Hans"
        }
        return nil
    }

}
