// 阅读路线
// 颜色模型负责通道数值和格式转换；屏幕像素的读取在 ScreenshotPixelSampler。
// 模型以 Double 保存 0...1 通道，格式化时再映射到 0...255；HEX/RGB/HSL 是不同文本表示。
// 官方参考（Swift 结构体与类）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/classesandstructures/

import Foundation

// ColorPickerFeature 模型使用 0...1 浮点数保存不可变颜色通道。
// CGFloat 常用于布局，Double 常用于数值计算；转换要显式写出，避免把点、像素和颜色通道混用。

/// 不可变颜色值对象，接近 Java record；初始化时统一钳制通道范围。
public struct SampledColor: Sendable, Equatable {
    /// 通道已经转换到 sRGB，范围为 0...1。
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
        self.alpha = min(max(alpha, 0), 1)
    }
}

/// 取色结果可复制和展示的文本格式。
public enum ColorFormat: String, CaseIterable, Sendable, Identifiable {
    case hex = "HEX"
    case rgb = "RGB"
    case hsl = "HSL"

    public var id: String { rawValue }
}

public extension SampledColor {
    // extension 把格式化行为添加到值类型上，不需要创建 Util 静态工具类。
    func formatted(as format: ColorFormat) -> String {
        switch format {
        case .hex:
            return String(
                format: "#%02X%02X%02X",
                Int((red * 255).rounded()),
                Int((green * 255).rounded()),
                Int((blue * 255).rounded())
            )
        case .rgb:
            return String(
                format: "rgb(%d, %d, %d)",
                Int((red * 255).rounded()),
                Int((green * 255).rounded()),
                Int((blue * 255).rounded())
            )
        case .hsl:
            let hsl = hslComponents()
            return String(format: "hsl(%.0f %.0f%% %.0f%%)", hsl.h, hsl.s * 100, hsl.l * 100)
        }
    }

    private func hslComponents() -> (h: Double, s: Double, l: Double) {
        // 命名 tuple 让调用方可写 hsl.h / hsl.s / hsl.l，同时不引入额外 DTO。
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let delta = maximum - minimum
        let lightness = (maximum + minimum) / 2

        // 最大通道等于最小通道时是灰色，没有可区分的色相；提前返回也避免后面除以 delta=0。
        guard delta > 0 else { return (0, 0, lightness) }

        let saturation = delta / (1 - abs(2 * lightness - 1))
        let hueSector: Double
        if maximum == red {
            hueSector = ((green - blue) / delta).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hueSector = (blue - red) / delta + 2
        } else {
            hueSector = (red - green) / delta + 4
        }
        // 加 360 再取余，将红色分支可能得到的负角度归一到 0..<360；格式化时才转成整数显示。
        let hue = (hueSector * 60 + 360).truncatingRemainder(dividingBy: 360)
        return (hue, saturation, lightness)
    }
}
