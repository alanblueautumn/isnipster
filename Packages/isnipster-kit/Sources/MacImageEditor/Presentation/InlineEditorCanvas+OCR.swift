import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// OCR 模式把鼠标拖动映射到字符首尾索引，按阅读顺序生成文本选择和高亮。
// 这里选中的是识别出的文本层，不是改动底图像素，也不生成绘图撤销命令。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import AppKit
import iSnipsterCore
import SwiftUI

extension InlineEditorCanvas {
    /// 整张截图作为一个文本选择平面；拖动起点和终点映射到 OCR 字符阅读顺序。
    func ocrInteractionOverlay(canvasSize: CGSize) -> some View {
        Canvas { context, _ in
            guard let range = session.selectedOCRCharacterRange,
                  range.lowerBound >= session.ocrCharacters.startIndex,
                  range.upperBound < session.ocrCharacters.endIndex else {
                return
            }
            var selectionPath = Path()
            for character in session.ocrCharacters[range] {
                let rect = ocrCharacterDisplayRect(
                    for: character,
                    canvasSize: canvasSize
                )
                selectionPath.addPath(Path(roundedRect: rect, cornerRadius: 2))
            }
            // 同向字符轮廓使用非零绕组规则一次填充，重叠处不会重复叠加透明度。
            context.fill(
                selectionPath,
                with: .color(Color.accentColor.opacity(0.16)),
                style: FillStyle(eoFill: false)
            )
        }
        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
        .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(ocrTextSelectionGesture(canvasSize: canvasSize))
        // 为 VoiceOver 提供语义标签；只有图标时尤其需要，不能只靠鼠标悬停提示表达动作。
        .accessibilityLabel(AppText.text("OCR 文本选择层"))
        .accessibilityHint(AppText.text("拖动选择文字后按 Command C 复制"))
    }

    private func ocrTextSelectionGesture(canvasSize: CGSize) -> some Gesture {
        // DragGesture 统一按下、移动和松开；onChanged 更新瞬时状态，onEnded 负责确认本次手势。
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let anchorIndex = ocrSelectionAnchorIndex ?? ocrCharacterIndex(
                    at: value.startLocation,
                    canvasSize: canvasSize
                )
                if ocrSelectionAnchorIndex == nil {
                    ocrSelectionAnchorIndex = anchorIndex
                }
                guard
                    let anchorIndex,
                    let currentIndex = ocrCharacterIndex(
                        at: value.location,
                        canvasSize: canvasSize
                    )
                else {
                    session.selectedOCRCharacterRange = nil
                    return
                }

                let lowerBound = min(anchorIndex, currentIndex)
                let upperBound = max(anchorIndex, currentIndex)
                let range = lowerBound...upperBound
                if session.selectedOCRCharacterRange != range {
                    session.selectedOCRCharacterRange = range
                }
                session.cursorSession.refresh()
            }
            .onEnded { _ in
                ocrSelectionAnchorIndex = nil
                session.cursorSession.refresh()
            }
    }

    private func ocrCharacterIndex(
        at point: CGPoint,
        canvasSize: CGSize
    ) -> Int? {
        var nearest: (index: Int, distance: CGFloat)?
        for (index, character) in session.ocrCharacters.enumerated() {
            let rect = ocrCharacterDisplayRect(for: character, canvasSize: canvasSize)
            if rect.contains(point) {
                return index
            }

            let horizontalDistance = max(
                max(rect.minX - point.x, 0),
                point.x - rect.maxX
            )
            let verticalDistance = max(
                max(rect.minY - point.y, 0),
                point.y - rect.maxY
            )
            let distance = hypot(horizontalDistance, verticalDistance)
            if nearest == nil || distance < nearest!.distance {
                nearest = (index, distance)
            }
        }

        guard let nearest else { return nil }
        return nearest.index
    }

    private func ocrCharacterDisplayRect(
        for character: OCRInteractionCharacter,
        canvasSize: CGSize
    ) -> CGRect {
        let normalized = character.normalizedRect
        let original = CGRect(
            x: normalized.minX * canvasSize.width,
            y: (1 - normalized.maxY) * canvasSize.height,
            width: normalized.width * canvasSize.width,
            height: normalized.height * canvasSize.height
        )
        let width = max(2, original.width + 1)
        let height = max(8, original.height + 2)
        return CGRect(
            x: original.midX - width / 2,
            y: original.midY - height / 2,
            width: width,
            height: height
        )
    }
}
