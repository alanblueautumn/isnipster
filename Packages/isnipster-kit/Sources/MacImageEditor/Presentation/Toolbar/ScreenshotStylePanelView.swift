import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 副工具栏把颜色、线宽、形状、文本字号与取色输出绑定到 session/document。
// 面板只选择参数；实际绘图由下一笔命令使用这些参数，已有标注不会因此整体重染。
// 官方参考（SwiftUI 状态与数据流）：https://developer.apple.com/documentation/swiftui/model-data

import ColorPickerFeature
import ImageEditorFeature
import Observation
import SwiftUI

/// 主工具栏下方的属性面板，只修改下一笔标注使用的样式。
@MainActor
struct ScreenshotStylePanelView: View {
    // @Bindable 为 @Observable 对象生成 $属性 绑定，类似 v-model 通道；对象的创建和共享仍由外层负责。
    @Bindable var session: InlineEditorSession
    let onAction: (ScreenshotToolbarAction) -> Void

    private var document: ImageDocument { session.document }
    private var supportsStrokeStyle: Bool { document.selectedTool.supportsStrokeColor }

    /// 按当前工具需要的控件计算面板尺寸，外层窗口布局据此为副工具栏留空间。
    static func preferredSize(for session: InlineEditorSession) -> CGSize {
        if session.showsTranslationOptions { return CGSize(width: 320, height: 42) }
        let width: CGFloat = switch session.document.selectedTool {
        case .redaction: 105
        case .text: 200
        default: 288
        }
        return CGSize(width: width, height: 76)
    }

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        Group {
            if session.showsTranslationOptions {
                ScreenshotTranslationStyleView(session: session, onAction: onAction)
            } else if document.selectedTool == .colorPicker {
                colorPickerResult
            } else if document.selectedTool == .text {
                textStyleControls
            } else if document.selectedTool == .redaction {
                colorPalette
                    // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                annotationStyleControls
            }
        }
        // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenshotToolbarChrome()
        // 只控制是否参与交互命中，不改变绘制或布局；适合让进度提示、装饰边框透传鼠标。
        .allowsHitTesting(!session.isProcessing)
    }

    private var annotationStyleControls: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        HStack(spacing: 8) {
            colorPalette

            Divider().frame(height: 54)

            strokeWidthOptions
                .frame(width: 77)

            Divider().frame(height: 54)

            Group {
                if document.selectedTool == .arrow {
                    Toggle("直线", isOn: arrowLineBinding)
                        .toggleStyle(.checkbox)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("实心", isOn: shapeFillBinding)
                        Toggle("椭圆", isOn: ellipseBinding)
                    }
                    .toggleStyle(.checkbox)
                    // 通过环境向子控件传递禁用状态；这是交互限制，耗时任务入口仍需要自己的重复调用防护。
                    .disabled(document.selectedTool != .rectangle)
                }
            }
            .font(.system(size: 13))
            .frame(width: 66, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var textStyleControls: some View {
        HStack(spacing: 8) {
            colorPalette

            Divider().frame(height: 54)

            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(36), spacing: 5), count: 2),
                spacing: 5
            ) {
                // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
                ForEach(Array(Self.textSizePresets.enumerated()), id: \.element) { index, size in
                    Button {
                        guard !session.isProcessing else { return }
                        session.selectTextFontSize(size)
                        // 副工具栏是独立 NSPanel；点击后交还焦点并触发统一光标重算。
                        onAction(.selectTool(.text))
                    } label: {
                        Circle()
                            .fill(Color.primary)
                            .frame(
                                width: Self.strokePreviewDiameter(for: CGFloat(index + 1) * 2),
                                height: Self.strokePreviewDiameter(for: CGFloat(index + 1) * 2)
                            )
                            .frame(width: 36, height: 25)
                            // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
                            .background(
                                session.textFontSize == size
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                            )
                            // overlay 在当前内容上层附加视图；纯装饰层可用 allowsHitTesting(false) 避免拦截底层交互。
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(
                                        session.textFontSize == size
                                            ? Color.accentColor.opacity(0.75)
                                            : Color.clear,
                                        lineWidth: 1
                                    )
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(AppText.format(.fontSize, Int(size)))
                    // 为 VoiceOver 提供语义标签；只有图标时尤其需要，不能只靠鼠标悬停提示表达动作。
                    .accessibilityLabel(AppText.format(.fontSize, Int(size)))
                }
            }
            .frame(width: 77)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var colorPalette: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(25), spacing: 5), count: 3),
            spacing: 5
        ) {
            ForEach(Array(paletteColors.enumerated()), id: \.offset) { _, color in
                colorButton(color, title: AppText.text(.useColor))
            }
        }
        .frame(width: 85)
        .disabled(!supportsStrokeStyle)
    }

    private var colorPickerResult: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(session.sampledColor?.rgbaColor.swiftUIColor ?? Color.clear)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.7)
                }
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                colorResultRow(format: .hex)
                colorResultRow(format: .rgb)
            }
        }
    }

    /// 显示当前采样色的指定格式与复制入口；格式变化不触发新的屏幕采样。
    private func colorResultRow(format: ColorFormat) -> some View {
        let placeholder = format == .hex ? "点击图片取色" : "松开鼠标完成"
        let value = session.sampledColor?.formatted(as: format) ?? placeholder
        return HStack(spacing: 6) {
            Text(value)
                .font(.system(
                    size: format == .hex ? 14 : 12,
                    weight: format == .hex ? .semibold : .regular,
                    design: .monospaced
                ))
                .foregroundStyle(format == .hex ? Color.primary : Color.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            copyColorButton(format: format)
        }
        .frame(height: 24)
    }

    /// 把复制意图及格式交给控制器，View 不直接写 NSPasteboard。
    private func copyColorButton(format: ColorFormat) -> some View {
        Button { onAction(.copySampledColor(format)) } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 16, weight: .regular))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.primary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(AppText.format(.copyFormat, format.rawValue))
        .accessibilityLabel(AppText.format(.copyFormat, format.rawValue))
        .disabled(session.sampledColor == nil)
    }

    private var strokeWidthOptions: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(36), spacing: 5), count: 2),
            spacing: 5
        ) {
            ForEach(Self.strokeWidthPresets, id: \.self) { width in
                Button {
                    guard !session.isProcessing else { return }
                    document.setStrokeWidth(width)
                } label: {
                    Circle()
                        .fill(Color.primary)
                        .frame(
                            width: Self.strokePreviewDiameter(for: width),
                            height: Self.strokePreviewDiameter(for: width)
                        )
                        .frame(width: 36, height: 25)
                        .background(
                            document.strokeStyle.width == width
                                ? Color.accentColor.opacity(0.12)
                                : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(
                                    document.strokeStyle.width == width
                                        ? Color.accentColor.opacity(0.75)
                                        : Color.clear,
                                    lineWidth: 1
                                )
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(AppText.format(.lineWidth, Int(width)))
            }
        }
        .disabled(!supportsStrokeStyle)
    }

    /// 渲染一个颜色选项并更新当前工具配置；选中外观与保存值使用同一颜色比较规则。
    private func colorButton(_ color: RGBAColor, title: String) -> some View {
        let isSelected = document.strokeStyle.color.matchesRGB(of: color)
        return Button {
            session.selectColor(color)
        } label: {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.swiftUIColor)
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.primary.opacity(0.18), lineWidth: 0.5)
                }
                .padding(2)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(
                            isSelected ? Color.accentColor : Color.clear,
                            lineWidth: 2
                        )
                }
                .frame(width: 25, height: 25)
        }
        .buttonStyle(.plain)
        .help(title)
    }

    private var shapeFillBinding: Binding<Bool> {
        // Binding(get:set:) 将现有状态投影为控件需要的值；类似 Vue computed 的读写代理。
        Binding(
            get: { document.shapeIsFilled },
            set: { value in
                guard !session.isProcessing else { return }
                document.shapeIsFilled = value
            }
        )
    }

    private var arrowLineBinding: Binding<Bool> {
        Binding(
            get: { document.arrowMode == .line },
            set: { value in
                guard !session.isProcessing else { return }
                document.arrowMode = value ? .line : .arrow
            }
        )
    }

    private var ellipseBinding: Binding<Bool> {
        Binding(
            get: { document.annotationShape == .ellipse },
            set: { value in
                guard !session.isProcessing else { return }
                document.annotationShape = value ? .ellipse : .rectangle
            }
        )
    }

    private static let presetColors: [RGBAColor] = [
        .red,
        RGBAColor(red: 1.00, green: 0.80, blue: 0.00),
        RGBAColor(red: 0.00, green: 0.48, blue: 1.00),
        RGBAColor(red: 0.20, green: 0.78, blue: 0.35),
        RGBAColor(red: 0.11, green: 0.11, blue: 0.12),
        RGBAColor(red: 1.00, green: 1.00, blue: 1.00)
    ]

    private static let strokeWidthPresets: [CGFloat] = [2, 4, 6, 8]
    private static let textSizePresets: [CGFloat] = [16, 20, 24, 32]

    /// 将实际线宽映射成便于比较的按钮预览尺寸；预览圆点尺寸不是最终标注像素宽度。
    private static func strokePreviewDiameter(for width: CGFloat) -> CGFloat {
        4 + width * 1.3
    }

    private var paletteColors: [RGBAColor] {
        Self.presetColors
    }
}

extension SampledColor {
    var rgbaColor: RGBAColor {
        RGBAColor(
            red: CGFloat(red),
            green: CGFloat(green),
            blue: CGFloat(blue),
            alpha: 1
        )
    }
}

extension RGBAColor {
    var swiftUIColor: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    /// 只比较颜色通道来判断调色板选中态，忽略不参与当前配置选择的其他状态。
    func matchesRGB(of other: RGBAColor) -> Bool {
        abs(red - other.red) < 0.005
            && abs(green - other.green) < 0.005
            && abs(blue - other.blue) < 0.005
    }
}
