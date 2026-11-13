import MacShared
import MacPreferences
import MacTranslation
// 阅读路线
// 按服务状态绘制加载、错误、译文与词典详情；折叠卡片只改变展示，不重建业务结果。
// 泛型 Content: View 允许详情容器接收不同内容，类似 Vue slot，但在 Swift 编译期检查类型。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import AVFoundation
import ClipboardFeature
import NaturalLanguage
import Observation
import TextTranslationFeature
import iSnipsterCore
import SwiftUI

/// 翻译结果区域拆到主视图的 extension，令 `TextTranslationView` 保持“页面编排”，这里负责“结果卡片渲染”。
/// SwiftUI 的 `some View` 是编译器保留的具体视图类型，效果类似 Vue 模板生成 VNode，但类型检查发生在编译期。
extension TextTranslationView {
    /// 依据该来源的加载/成功/失败状态绘制卡片，并复用同一折叠状态控制详情显隐。
    func resultCard(_ provider: TextTranslationProvider) -> some View {
        let state = model.results[provider] ?? .idle
        let isCollapsed = collapsedProviders.contains(provider)

        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        return VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button {
                    toggleResultCard(provider, isCollapsed: isCollapsed)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: provider.systemImage)
                            .foregroundStyle(
                                provider == .apple ? Color.primary : Color.accentColor
                            )
                        Text(AppText.format("%@ 翻译", provider.title))
                            .font(.subheadline.weight(.semibold))
                        if let errorMessage = state.errorMessage {
                            Text(AppText.text("请求失败"))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.orange)
                                .help(errorMessage)
                        }
                        Spacer()
                        if state.isLoading {
                            ProgressView()
                                .controlSize(.mini)
                                // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                                .frame(width: 20, height: 20)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)

                if state.output != nil {
                    Button {
                        model.copyResult(from: provider)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.plain)
                    .frame(width: 24, height: 24)
                    .modifier(TranslationButtonHoverBackground())
                    .help(AppText.text("复制译文"))
                }
                Button {
                    toggleResultCard(provider, isCollapsed: isCollapsed)
                } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .contentTransition(.symbolEffect(.replace))
                        .animation(.easeOut(duration: 0.12), value: isCollapsed)
                }
                .buttonStyle(.plain)
                .frame(width: 24, height: 24)
                .modifier(TranslationButtonHoverBackground())
                .help(isCollapsed ? AppText.text("展开翻译内容") : AppText.text("收起翻译内容"))
            }
            // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
            .padding(.horizontal, 10)
            .frame(height: 34)

            if !isCollapsed, !state.isIdle, !state.isLoading {
                Divider().opacity(0.55)
                Group {
                    if let output = state.output {
                        translationOutput(output, provider: provider)
                    } else {
                        Label(
                            state.errorMessage ?? AppText.text("翻译失败"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.78))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 9)
                .padding(.top, 6)
                .padding(.bottom, 8)
            }
        }
        // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.14), lineWidth: 0.8)
        }
    }

    private func translationOutput(
        _ output: TextTranslationOutput,
        provider: TextTranslationProvider
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !output.details.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(model.sourceText.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .textSelection(.enabled)

                    if !output.details.examTypes.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: 6) {
                                // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
                                ForEach(output.details.examTypes, id: \.self) { type in
                                    examTypeTag(type)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }

                    Spacer(minLength: 0)
                }
            }

            primaryTranslationSection(output.primaryText, provider: provider)

            if !output.details.phonetics.isEmpty {
                resultDetailSection {
                    HStack(spacing: 12) {
                        ForEach(output.details.phonetics.indices, id: \.self) { index in
                            let phonetic = output.details.phonetics[index]
                            if index > 0 {
                                Divider()
                                    .frame(height: 18)
                            }

                            HStack(spacing: 6) {
                                Text(phonetic.label)
                                    .font(.system(size: 12, design: .rounded))
                                    .foregroundStyle(.secondary)
                                Text("/ \(phonetic.value) /")
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                                Button {
                                    model.speakSource(accent: phonetic.label)
                                } label: {
                                    Image(systemName: "speaker.wave.2")
                                }
                                .buttonStyle(.plain)
                                .frame(width: 24, height: 24)
                                .modifier(TranslationButtonHoverBackground())
                                .focusable(false)
                                .help(AppText.format("播放%@式读音", phonetic.label))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if !output.details.definitions.isEmpty || !output.details.wordForms.isEmpty {
                resultDetailSection {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(output.details.definitions) { definition in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                if let label = definition.label, !label.isEmpty {
                                    Text(label)
                                        .font(.system(size: 14, design: .rounded))
                                        .foregroundStyle(.secondary)
                                }
                                Text(definition.meaning)
                                    .textSelection(.enabled)
                                    .lineSpacing(3)
                            }
                        }

                        if !output.details.wordForms.isEmpty {
                            TranslationTagFlowLayout(horizontalSpacing: 5, verticalSpacing: 5) {
                                ForEach(output.details.wordForms) { form in
                                    Text("\(form.name)  \(form.value)")
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .lineLimit(1)
                                        .fixedSize()
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(
                                            Color.primary.opacity(0.07),
                                            in: Capsule()
                                        )
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            if !output.details.phrases.isEmpty {
                resultDetailSection {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(output.details.phrases) { phrase in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(phrase.text)
                                    .font(.system(size: 14, design: .rounded))
                                    .foregroundStyle(Color.accentColor.opacity(0.82))
                                    .textSelection(.enabled)
                                Text(phrase.meanings.joined(separator: "；"))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func primaryTranslationSection(
        _ translatedText: String,
        provider: TextTranslationProvider
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(translatedText)
                .font(.system(size: 14, design: .rounded))
                .foregroundStyle(Color.primary.opacity(0.78))
                .textSelection(.enabled)
                .lineSpacing(2)
            Spacer(minLength: 6)
            Button {
                model.speakResult(from: provider)
            } label: {
                Image(systemName: "speaker.wave.2")
            }
            .buttonStyle(.plain)
            .frame(width: 22, height: 22)
            .modifier(TranslationButtonHoverBackground())
            .focusable(false)
            .help(AppText.text("朗读译文"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func examTypeTag(_ type: String) -> some View {
        Text(type)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.secondary.opacity(0.55)))
    }

    /// 用泛型内容闭包复用详情分组外观，像带标题的 Vue slot 容器。
    private func resultDetailSection<Content: View>(
        // @ViewBuilder 是结果构建器：把闭包内的多个 View 和条件分支组合成一个静态类型的视图结果。
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private func toggleResultCard(
        _ provider: TextTranslationProvider,
        isCollapsed: Bool
    ) {
        // 展开时才补发请求：折叠卡片不占用网络或系统翻译会话，类似 Vue 中按需挂载的异步组件。
        if isCollapsed {
            collapsedProviders.remove(provider)
            model.translateIfNeeded(for: provider)
        } else {
            collapsedProviders.insert(provider)
        }
    }
}
