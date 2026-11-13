import MacShared
import MacPreferences
import MacTranslation
// 阅读路线
// 页面组织输入、结果和弹层，测量内容后通过回调请求外层窗口调整高度。
// 它同时承载系统 translationTask；模型发布配置，系统把 TranslationSession 回传给客户端消费。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import AVFoundation
import ClipboardFeature
import NaturalLanguage
import Observation
import TextTranslationFeature
import iSnipsterCore
import SwiftUI

/// 文本翻译窗口的 SwiftUI 内容视图，展示输入区、翻译源状态和详细结果。
@MainActor
struct TextTranslationView: View {
    // @Bindable 为 @Observable 对象生成 $属性 绑定，类似 v-model 通道；对象的创建和共享仍由外层负责。
    @Bindable var model: TextTranslationModel
    let translationClient: AppleTranslationClient
    let onPinChange: (Bool) -> Void
    let onWindowDragEnd: () -> Void
    let onPreferredHeightChange: (CGFloat) -> Void
    let maximumWindowHeight: () -> CGFloat
    let onClose: () -> Void
    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State var isPinned: Bool
    @State var isShowingHistory = false
    @State var isShowingProviderSettings = false
    @State var collapsedProviders: Set<TextTranslationProvider> = []
    @State private var sourceTextContentHeight: CGFloat = 88
    @State private var sourceEditorHeight: CGFloat = 0
    @State private var messageHeight: CGFloat = 0
    @State private var resultsContentHeight: CGFloat = 0

    init(
        model: TextTranslationModel,
        translationClient: AppleTranslationClient,
        initiallyPinned: Bool,
        onPinChange: @escaping (Bool) -> Void,
        onWindowDragEnd: @escaping () -> Void,
        onPreferredHeightChange: @escaping (CGFloat) -> Void,
        maximumWindowHeight: @escaping () -> CGFloat,
        onClose: @escaping () -> Void
    ) {
        self.model = model
        self.translationClient = translationClient
        self.onPinChange = onPinChange
        self.onWindowDragEnd = onWindowDragEnd
        self.onPreferredHeightChange = onPreferredHeightChange
        self.maximumWindowHeight = maximumWindowHeight
        self.onClose = onClose
        _isPinned = State(initialValue: initiallyPinned)
        _collapsedProviders = State(initialValue: Set(model.availableProviders))
    }

    /// VStack 的间距决定纵向节奏；background 叠材质与底色，clipShape 约束最终圆角。
    /// onChange 类似 Vue watch，只响应指定状态变化；translationTask 承载系统翻译会话。
    var body: some View {
        // GeometryReader 提供父布局给出的可用尺寸，单位为 point；布局尺寸不等于截图的像素尺寸。
        GeometryReader { geometry in
            // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
            VStack(spacing: 5) {
                header
                sourceEditor(
                    maxTextHeight: sourceTextMaximumHeight
                )
                // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
                .background(TranslationSourceEditorHeightReader())

                if let message = model.message {
                    Label(
                        message,
                        systemImage: model.failed
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(model.failed ? Color.orange : Color.secondary)
                    // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TranslationMessageHeightReader())
                }

                ScrollView {
                    VStack(spacing: 4) {
                        if model.displayedProviders.isEmpty {
                            ContentUnavailableView(
                                AppText.text("等待翻译"),
                                systemImage: "character.bubble",
                                description: Text(AppText.text("输入文本后按回车查询已启用的翻译源"))
                            )
                            .frame(minHeight: 250)
                        } else {
                            // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
                            ForEach(model.displayedProviders) { provider in
                                resultCard(provider)
                            }
                        }
                    }
                    .background(TranslationResultsHeightReader())
                }
                .scrollIndicators(showsResultsScrollIndicator ? .automatic : .hidden)
                .contentMargins(.trailing, 12, for: .scrollIndicators)
            }
            // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 6)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background {
                let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
                ZStack {
                    Color.clear.isnipsterGlass(
                        shape,
                        tint: Color.cyan.opacity(0.025)
                    )
                    shape.fill(
                        Color(nsColor: .windowBackgroundColor).opacity(0.60)
                    )
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        // onChange 类似 Vue watch：状态变化后执行副作用；仅监听值变化，不代表每次 body 求值都会调用。
        .onChange(of: model.translationSequence) { _, _ in
            collapsedProviders = Set(model.availableProviders)
        }
        .onChange(of: model.results) { previous, current in
            for provider in model.availableProviders
            where previous[provider]?.output == nil && current[provider]?.output != nil {
                collapsedProviders.remove(provider)
            }
        }
        .onChange(of: model.availableProviders) { previous, current in
            collapsedProviders.formUnion(Set(current).subtracting(previous))
        }
        .onPreferenceChange(TranslationSourceEditorHeightPreferenceKey.self) { height in
            sourceEditorHeight = height
        }
        .onPreferenceChange(TranslationMessageHeightPreferenceKey.self) { height in
            messageHeight = height
        }
        .onPreferenceChange(TranslationResultsHeightPreferenceKey.self) { height in
            resultsContentHeight = height
        }
        .onChange(of: preferredWindowHeight, initial: true) { _, height in
            guard height > 0 else { return }
            onPreferredHeightChange(height)
        }
        // SwiftUI 提供与当前配置关联的 TranslationSession；客户端在回调里消费请求，而非自行持有系统会话。
        .appleTranslationHost(translationClient)
    }

    private var sourceTextMaximumHeight: CGFloat {
        max(88, (NSScreen.main?.frame.height ?? 900) * 0.3)
    }

    private var showsResultsScrollIndicator: Bool {
        preferredWindowHeight
            > maximumWindowHeight() + 0.5
    }

    /// 对齐 Easydict：窗口高度等于可见内容总高，超过屏幕上限后只压缩结果滚动区。
    private var preferredWindowHeight: CGFloat {
        guard sourceEditorHeight > 0, resultsContentHeight > 0 else { return 0 }
        let hasMessage = model.message != nil
        guard !hasMessage || messageHeight > 0 else { return 0 }
        let arrangedViewCount: CGFloat = hasMessage ? 4 : 3
        let verticalSpacing = (arrangedViewCount - 1) * 5
        let measuredMessageHeight = hasMessage ? messageHeight : 0
        return ceil(
            4 + 6
                + 22
                + sourceEditorHeight
                + measuredMessageHeight
                + resultsContentHeight
                + verticalSpacing
        )
    }

    /// 输入框通过 Binding 写入 Model；输入区样式与请求逻辑分离，避免渲染时触发翻译。
    private func sourceEditor(maxTextHeight: CGFloat) -> some View {
        let editorHeight = min(max(88, sourceTextContentHeight), maxTextHeight)
        let needsScrolling = sourceTextContentHeight > maxTextHeight

        return VStack(spacing: 6) {
            GeometryReader { geometry in
                TextEditor(text: $model.sourceText)
                    .font(.system(size: 14, design: .rounded))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(needsScrolling ? .automatic : .hidden)
                    .scrollDisabled(!needsScrolling)
                    .textEditorStyle(.plain)
                    // 视图进入显示层级时执行，可重复触发；需要一次性语义的业务逻辑仍应由状态或服务保证。
                    .onAppear {
                        updateSourceTextHeight(width: geometry.size.width)
                    }
                    .onChange(of: model.sourceText) { _, _ in
                        updateSourceTextHeight(width: geometry.size.width)
                    }
                    .onChange(of: geometry.size.width) { _, width in
                        updateSourceTextHeight(width: width)
                    }
            }
            .frame(height: editorHeight)

            footer
        }
        .padding(12)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 17, style: .continuous)
        )
        // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.8)
        }
    }

    /// 在给定宽度下测量输入文本高度，供窗口内容尺寸计算使用；不改变输入文本本身。
    private func updateSourceTextHeight(width: CGFloat) {
        guard width > 10 else { return }
        let baseFont = NSFont.systemFont(ofSize: 14)
        let descriptor = baseFont.fontDescriptor.withDesign(.rounded) ?? baseFont.fontDescriptor
        let font = NSFont(descriptor: descriptor, size: 14) ?? baseFont
        let measuredText = model.sourceText.isEmpty ? " " : model.sourceText + " "
        let bounds = (measuredText as NSString).boundingRect(
            with: NSSize(
                width: width - 10,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        sourceTextContentHeight = max(88, ceil(bounds.height) + 16)
    }

}
