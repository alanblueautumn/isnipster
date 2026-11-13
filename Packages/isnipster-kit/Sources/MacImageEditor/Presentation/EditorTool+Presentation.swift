import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 为领域工具补上 UI 标题/图标/能力描述；展示字段放在平台层，业务模型不依赖 SwiftUI。
// extension 类似按职责拆分一个类型的实现，本身不构成子类，也不复制工具对象。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import ImageEditorFeature

extension EditorTool {
    var title: String {
        switch self {
        case .rectangle: "矩形"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .redaction: "实心打码"
        case .text: "标注文本"
        case .step: "标注步骤"
        case .colorPicker: "吸管取色"
        }
    }

    var systemImage: String {
        switch self {
        case .rectangle: "rectangle.dashed"
        case .arrow: "arrow.up.right"
        case .pen: "pencil.tip"
        case .redaction: "rectangle.fill"
        case .text: "character"
        case .step: "1.circle"
        case .colorPicker: "eyedropper"
        }
    }

    /// 只有会读取 ImageDocument.strokeStyle.color 的工具才展示颜色面板。
    /// 这是能力判断，而不是在 View 中散落多个 `tool == ...` 条件。
    var supportsStrokeColor: Bool {
        switch self {
        case .rectangle, .arrow, .pen, .text, .step, .redaction: true
        case .colorPicker: false
        }
    }

    var colorOptionTitle: String {
        switch self {
        case .rectangle: "矩形边框颜色"
        case .arrow: "箭头颜色"
        case .pen: "画笔颜色"
        case .redaction: "打码颜色"
        case .text: "文字颜色"
        case .step: "步骤标记颜色"
        case .colorPicker: "取色结果"
        }
    }
}
