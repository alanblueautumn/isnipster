import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 画布根 View 组合底图、命令预览、手势、文字输入和 OCR 层；状态来自共享 session。
// GeometryReader 给出显示尺寸，手势位置必须先换算为原图像素再写入编辑命令。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import CaptureFeature
import ClipboardFeature
import ColorPickerFeature
import CoreImage
import CoreText
import ImageEditorFeature
import ImageTranslationFeature
import Observation
import iSnipsterCore
import SwiftUI
@preconcurrency import Translation

struct CommittedTextMoveState {
    let id: UUID
    let originalRect: CGRect
    let visibleBounds: CGRect
    let currentOrigin: CGPoint
}

/// 在原截图选区上显示位图、标注操作和手势反馈的 SwiftUI 画布。
@MainActor
struct InlineEditorCanvas: View {
    // @Bindable 取得 Observable 对象的双向绑定能力；对象所有权仍在 Controller/session。
    @Bindable var session: InlineEditorSession
    let onCancel: () -> Void
    let translationClient: AppleTranslationClient
    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State var ocrSelectionAnchorIndex: Int? = nil
    @State var committedTextMove: CommittedTextMoveState? = nil

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // GeometryReader 提供父布局给出的可用尺寸，单位为 point；布局尺寸不等于截图的像素尺寸。
        GeometryReader { proxy in
            let displayRect = CGRect(origin: .zero, size: proxy.size)
            // Canvas 类似立即模式绘图表面：状态变化时 SwiftUI 重新执行绘制闭包，
            // 但不会在每次鼠标移动时生成新的 CGImage。
            ZStack(alignment: .topLeading) {
                Canvas { context, _ in
                    context.draw(
                        Image(decorative: session.document.original.cgImage, scale: 1),
                        in: displayRect
                    )
                    drawOperations(
                        session.document.operations,
                        context: &context,
                        displayRect: displayRect
                    )
                    drawDraft(context: &context, displayRect: displayRect)
                }
                .contentShape(Rectangle())
                .gesture(editGesture(canvasSize: proxy.size))

                if session.isOCRMode {
                    ocrInteractionOverlay(canvasSize: proxy.size)
                }

                if session.document.selectedTool == .text,
                   let origin = session.textEntryOrigin {
                    inlineTextEditor(origin: origin, canvasSize: proxy.size)
                }
            }
        }
        // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
        .overlay {
            ZStack {
                Rectangle()
                    // 调整态由 AppKit 画蓝框，确认后画布位于它的上层，因此这里继续绘制
                    // 同色固定边框。使用 strokeBorder 向内绘制，不改变 NSPanel 的几何位置。
                    .strokeBorder(Color(nsColor: .systemBlue), lineWidth: 1.5)

                if let message = session.centeredProgressMessage {
                    VStack(spacing: 8) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.regular)
                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
                    .background(
                        Color(nsColor: .windowBackgroundColor).opacity(0.94),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.primary.opacity(0.12), lineWidth: 0.7)
                    }
                } else if let message = session.errorMessage {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
                }
            }
            // 加载提示只是视觉反馈：智能打码期间用户仍可拖动补充实心色块。
            .allowsHitTesting(false)
        }
        // 窗口首帧尚未合成时透明背景会显示下方原屏幕，不会闪出黑色占位帧。
        .background(Color.clear)
        .onExitCommand(perform: onCancel)
        // SwiftUI 提供与当前配置关联的 TranslationSession；客户端在回调里消费请求，而非自行持有系统会话。
        .appleTranslationHost(translationClient)
    }

    /// DragGesture 类似 pointerdown/move/up 的组合；onChanged 只更新草稿，onEnded 才提交。
    /// canvasSize 是逻辑点，Session 再换算成原图像素，因此缩放画布不会改变标注数据。
    private func editGesture(canvasSize: CGSize) -> some Gesture {
        // minimumDistance: 0 让单击也进入手势，可用于文字落点和步骤编号落点。
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !session.isOCRMode else { return }
                guard !session.isProcessing || session.allowsCanvasEditingWhileProcessing else { return }
                if session.document.selectedTool == .text {
                    guard session.textEntryOrigin == nil else { return }
                    let move: CommittedTextMoveState
                    if let currentMove = committedTextMove {
                        move = currentMove
                    } else {
                        guard let target = session.committedTextRegion(
                            at: value.startLocation,
                            canvasSize: canvasSize
                        ) else { return }
                        move = CommittedTextMoveState(
                            id: target.id,
                            originalRect: target.rect,
                            visibleBounds: target.visibleBounds,
                            currentOrigin: target.rect.origin
                        )
                    }

                    let imageSize = session.document.imageSize
                    let scaleX = canvasSize.width / max(imageSize.width, 1)
                    let scaleY = canvasSize.height / max(imageSize.height, 1)
                    let destination = CGPoint(
                        x: min(
                            max(
                                move.originalRect.minX - move.visibleBounds.minX,
                                move.originalRect.minX + value.translation.width / max(scaleX, 0.001)
                            ),
                            move.originalRect.minX + max(0, imageSize.width - move.visibleBounds.width)
                                - move.visibleBounds.minX
                        ),
                        y: min(
                            max(
                                move.originalRect.minY - move.visibleBounds.minY,
                                move.originalRect.minY + value.translation.height / max(scaleY, 0.001)
                            ),
                            move.originalRect.minY + max(0, imageSize.height - move.visibleBounds.height)
                                - move.visibleBounds.minY
                        )
                    )
                    committedTextMove = CommittedTextMoveState(
                        id: move.id,
                        originalRect: move.originalRect,
                        visibleBounds: move.visibleBounds,
                        currentOrigin: destination
                    )
                    session.isMovingText = true
                    session.cursorSession.refresh()
                    return
                }
                guard session.document.selectedTool != .colorPicker else { return }
                session.updateDrag(at: value.location, canvasSize: canvasSize)
            }
            .onEnded { value in
                guard !session.isOCRMode else {
                    session.cancelDraft()
                    return
                }
                guard !session.isProcessing || session.allowsCanvasEditingWhileProcessing else {
                    session.cancelDraft()
                    return
                }
                if session.document.selectedTool == .colorPicker {
                    // 放大镜跟随鼠标预览，松开时才确认颜色并更新标注样式。
                    session.sampleColor(at: value.location, canvasSize: canvasSize)
                } else if session.document.selectedTool == .text {
                    if let move = committedTextMove {
                        session.document.moveText(id: move.id, to: move.currentOrigin)
                        committedTextMove = nil
                        session.isMovingText = false
                        session.cursorSession.refresh()
                    } else {
                        if session.textEntryOrigin != nil {
                            session.commitTextEntry()
                        } else {
                            session.beginTextEntry(at: value.location, canvasSize: canvasSize)
                        }
                        session.cursorSession.refresh(afterTransition: true)
                    }
                } else {
                    session.commitDraft()
                }
            }
    }

}
