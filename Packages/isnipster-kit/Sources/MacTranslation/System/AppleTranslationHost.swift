import MacShared
import SwiftUI
@preconcurrency import Translation

/// 将系统会话宿主与具体截图画布、翻译界面分开，两个功能分别注入自己的客户端。
public extension View {
    func appleTranslationHost(_ client: AppleTranslationClient) -> some View {
        modifier(AppleTranslationHost(client: client))
    }
}

private struct AppleTranslationHost: ViewModifier {
    let client: AppleTranslationClient

    func body(content: Content) -> some View {
        content.translationTask(client.configuration) { session in
            await client.consume(using: session)
        }
    }
}
