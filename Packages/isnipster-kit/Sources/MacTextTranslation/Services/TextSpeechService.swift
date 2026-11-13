import AVFoundation

@MainActor
final class TextSpeechService {
    private let speechSynthesizer = AVSpeechSynthesizer()
    func stop() { speechSynthesizer.stopSpeaking(at: .immediate) }

    func speak(_ text: String, language: String?) {
        if speechSynthesizer.isSpeaking {
            speechSynthesizer.stopSpeaking(at: .immediate)
        }
        // AVSpeechUtterance 是一次朗读的文本与语音参数；交给 AVSpeechSynthesizer 后由系统语音引擎播放。
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = language.flatMap {
            AVSpeechSynthesisVoice(language: speechLocaleIdentifier(for: $0))
        }
        utterance.rate = 0.46
        speechSynthesizer.speak(utterance)
    }

    private func speechLocaleIdentifier(for language: String) -> String {
        switch language {
        case "zh-Hans": "zh-CN"
        case "zh-Hant": "zh-TW"
        case "en-US": "en-US"
        case "ja-JP": "ja-JP"
        case "ko-KR": "ko-KR"
        default: language
        }
    }

}
