import MacShared
import MacScreenshotSupport
import MacTranslation
import RecognitionFeature
// 阅读路线
// 把正则 NSRange 转为 OCR 字符矩形；还会拼接同一行相邻数字块后重新识别号码。
// 没有精确字符框时放弃局部命中，避免估算框遮住旁边非敏感文字。
// 官方参考（Vision 文字与区域）：https://developer.apple.com/documentation/vision/vnrecognizedtext

import CoreGraphics
import Foundation
import ImageEditorFeature
import ImageTranslationFeature

enum RedactionTextLocator {
    static func rects(for ranges: [NSRange], in region: OCRTextRegion) -> [CGRect] {
        let fullRange = NSRange(region.text.startIndex..<region.text.endIndex, in: region.text)
        return ranges.compactMap { range in
            guard range.location >= 0, range.length > 0, NSMaxRange(range) <= NSMaxRange(fullRange) else { return nil }
            if range == fullRange { return region.normalizedRect }
            // 只有字符拼接与 OCR 原文一致时才能按下标映射，避免修剪/识别差异使敏感范围落到错误字符上。
            guard region.characters.map(\.text).joined() == region.text else { return nil }

            // 每个 Swift Character 可能占多个 UTF-16 单元；按 utf16.count 累加，才能与正则返回的 NSRange 对齐。
            var offset = 0
            var selected: [CGRect] = []
            var neighbors: [CGRect] = []
            for character in region.characters {
                let characterRange = NSRange(location: offset, length: character.text.utf16.count)
                offset = NSMaxRange(characterRange)
                guard !character.text.allSatisfy(\.isWhitespace) else { continue }
                if NSIntersectionRange(characterRange, range).length > 0 {
                    guard character.hasPreciseBounds, !character.normalizedRect.isEmpty,
                          !character.normalizedRect.isNull else { return nil }
                    selected.append(character.normalizedRect)
                } else {
                    neighbors.append(character.normalizedRect)
                }
            }
            guard let first = selected.first else { return nil }
            let rect = selected.dropFirst().reduce(first) { $0.union($1) }
            // Vision 偶尔为一个字返回整个词框；局部打码不能借此遮住同词中的非敏感字符。
            guard !neighbors.contains(where: { RedactionGeometry.coverage(of: $0, by: rect) > 0.25 }) else { return nil }
            return rect.intersection(region.normalizedRect)
        }
    }

    /// 只拼接同一行、紧邻的数字块。不会跨聊天气泡或跨行凑足一个号码。
    static func joinedNumberRects(texts: [OCRTextRegion], layout: [RedactionTextLayout]) -> [CGRect] {
        let numeric = layout.filter {
            $0.confidence >= 0.7 && $0.text.count <= 24
                && $0.text.contains(where: \.isNumber)
                && $0.text.allSatisfy { "0123456789０１２３４５６７８９+-＋－()（） 　*xX＊ｘＸ•●·".contains($0) }
        }
        var consumed: Set<Int> = []
        var result: [CGRect] = []
        for start in numeric.sorted(by: { $0.rect.minX < $1.rect.minX }) where !consumed.contains(start.index) {
            var run = [start]
            while run.count < 6, let last = run.last {
                let next = layout.filter { candidate in
                    let height = max(last.rect.height, candidate.rect.height)
                    let gap = candidate.rect.minX - last.rect.maxX
                    return candidate.index != last.index && gap >= 0 && gap <= height * 0.85
                        && abs(candidate.rect.midY - last.rect.midY) <= height * 0.25
                }.min { $0.rect.minX < $1.rect.minX }
                guard let next, !consumed.contains(next.index),
                      !run.contains(where: { $0.index == next.index }),
                      numeric.contains(where: { $0.index == next.index }) else { break }
                run.append(next)
            }
            consumed.formUnion(run.map(\.index))
            guard run.count >= 2 else { continue }
            let joined = run.map(\.text).joined(separator: " ")
            let matches = SensitiveTextDetector.ranges(in: joined)
            for match in matches {
                var offset = 0
                var pieces: [(Int, NSRange)] = []
                for part in run {
                    let range = NSRange(location: offset, length: part.text.utf16.count)
                    let overlap = NSIntersectionRange(range, match)
                    if overlap.length > 0 {
                        pieces.append((part.index, NSRange(location: overlap.location - offset, length: overlap.length)))
                    }
                    offset = NSMaxRange(range) + 1
                }
                guard pieces.count >= 2 else { continue }
                let located = pieces.map { rects(for: [$0.1], in: texts[$0.0]) }
                guard located.allSatisfy({ !$0.isEmpty }) else { continue }
                result += located.flatMap { $0 }
            }
        }
        return result
    }
}
