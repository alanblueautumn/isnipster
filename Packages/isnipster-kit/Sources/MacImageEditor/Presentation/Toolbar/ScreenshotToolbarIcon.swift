import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 把工具语义映射为资源图标，统一尺寸与渲染方式；资源来自当前 SwiftPM 模块。
// 模板渲染会使用外层前景色，原始渲染则保留图像颜色，两者适用场景不同。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import SwiftUI

// Official Lucide SVGs, unmodified from c2c28580b3009b8de62224c1fec6f78abb3e37d8.
// ISC/MIT notices are shipped in Lucide-LICENSE.txt.
struct ScreenshotToolbarIcon: View {
    enum Symbol {
        case rectangle, arrow, pen, text, step, colorPicker
        case ocr, translation, redaction
        case pin, undo, redo, save, cancel, confirm

        var assetName: String {
            switch self {
            case .rectangle: "lucide-rectangle-horizontal"
            case .arrow: "lucide-move-up-right"
            case .pen: "lucide-pencil"
            case .text: "lucide-type"
            case .step: "lucide-list-ordered"
            case .colorPicker: "lucide-pipette"
            case .ocr: "lucide-scan-text"
            case .translation: "lucide-languages"
            case .redaction: "lucide-eye-off"
            case .pin: "lucide-pin"
            case .undo: "lucide-undo-2"
            case .redo: "lucide-redo-2"
            case .save: "lucide-download"
            case .cancel: "lucide-x"
            case .confirm: "lucide-check"
            }
        }
    }

    let symbol: Symbol

    init(_ symbol: Symbol) {
        self.symbol = symbol
    }

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        Image(symbol.assetName, bundle: AppResources.bundle)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
            .frame(width: 24, height: 24)
            .frame(width: 28, height: 26)
            // 控制辅助功能树中的可见性，不改变屏幕显示；装饰图标可隐藏，动作语义由外层按钮提供。
            .accessibilityHidden(true)
    }
}
