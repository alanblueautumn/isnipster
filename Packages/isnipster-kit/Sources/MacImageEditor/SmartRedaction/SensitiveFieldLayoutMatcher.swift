import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 先识别字段标签，再找右侧或下方最近值；地址允许延续有限行，昵称/密码不向下猜测。
// 距离阈值按字高缩放，使同一规则可用于不同字号与截图分辨率。
// 官方参考（Vision 文字与区域）：https://developer.apple.com/documentation/vision/vnrecognizedtext

import CoreGraphics
import Foundation
import ImageEditorFeature

/// 只关联最近的字段值，不越过其它文字去寻找一个“看起来敏感”的候选。
enum SensitiveFieldLayoutMatcher {
    static func matchingIndices(in texts: [RedactionTextLayout]) -> Set<Int> {
        var result: Set<Int> = []
        for label in texts where label.confidence >= 0.65 {
            guard let rule = SensitiveFieldKind.allCases.first(where: { $0.isLabel(label.text) }) else { continue }
            let neighbors = texts.filter { $0.index != label.index }
            // 以字高作为距离单位，并约束中心线高度；先找最近候选，再判断业务值，不能越过近邻去挑远处的敏感文本。
            let right = neighbors.filter { value in
                let height = max(label.rect.height, value.rect.height)
                let gap = value.rect.minX - label.rect.maxX
                return gap >= -height * 0.1 && gap <= height * 4
                    && abs(value.rect.midY - label.rect.midY) <= height * 0.35
            }.min { $0.rect.minX < $1.rect.minX }
            let below = neighbors.filter { value in
                let height = max(label.rect.height, value.rect.height)
                let gap = label.rect.minY - value.rect.maxY
                return gap >= 0 && gap <= height
                    && abs(value.rect.minX - label.rect.minX) <= height * 0.5
            }.max { $0.rect.maxY < $1.rect.maxY }
            // 昵称/密码不向下一行推断，避免表单标签旁的提示词和聊天正文被选中。
            let candidate = right ?? ((rule == .nickname || rule == .credential) ? nil : below)
            guard let candidate, candidate.confidence >= 0.65,
                  !SensitiveFieldKind.allCases.contains(where: { $0.isLabel(candidate.text) }),
                  rule.isValue(candidate.text) else { continue }
            result.insert(candidate.index)

            if rule == .address {
                var previous = candidate
                for _ in 0..<2 {
                    let continuation = neighbors.filter { value in
                        let height = max(previous.rect.height, value.rect.height)
                        let gap = previous.rect.minY - value.rect.maxY
                        return gap > 0 && gap <= height * 0.9
                            && abs(value.rect.minX - candidate.rect.minX) <= height * 0.5
                    }.max { $0.rect.maxY < $1.rect.maxY }
                    guard let next = continuation, next.confidence >= 0.7,
                          next.text.range(of: #"^[A-Za-z0-9一二三四五六七八九十-]+(?:栋|幢|单元|室|楼)(?:[A-Za-z0-9一二三四五六七八九十-]+(?:栋|幢|单元|室|楼))*$"#,
                                          options: .regularExpression) != nil else { break }
                    result.insert(next.index)
                    previous = next
                }
            }
        }
        return result
    }
}
