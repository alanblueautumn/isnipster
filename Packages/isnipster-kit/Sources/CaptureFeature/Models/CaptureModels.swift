// 阅读路线
// 沿 ScreenCaptureTarget → FrozenScreenFrame → ScreenSelection → CapturedRegion 看一次截图的数据流。
// 牢记三种坐标：桌面全局 point、屏幕内左上 point、图片 pixel；每次转换先确认原点和倍率。
// 官方参考（CGImage 像素图像）：https://developer.apple.com/documentation/coregraphics/cgimage

import CoreGraphics
import Foundation
import iSnipsterCore

// CaptureFeature 模型提示：逻辑点类似 CSS px，物理像素类似 CSS px × devicePixelRatio。
// AppKit 窗口通常以左下为原点；这里的图片选区以左上为原点。iOS UIKit 通常也用左上原点，迁移时不能照搬翻转公式。

/// 一次截图会话对应的物理显示器。
///
/// CaptureFeature 不认识 NSScreen，因此把平台层真正需要的四项信息收敛成值对象：
/// 显示器 ID、ScreenCaptureKit 使用的全局坐标、AppKit 放置窗口使用的全局坐标，
/// 以及逻辑点到像素的建议缩放倍率。
/// Java 对照：这是跨模块传递的不可变 DTO，不包含任何 NSWindow 等 UI 对象。
public struct ScreenCaptureTarget: Sendable, Equatable {
    public let displayID: UInt32
    public let rectInCaptureSpace: CGRect
    public let globalRect: CGRect
    public let displayScale: CGFloat

    public init(
        displayID: UInt32,
        rectInCaptureSpace: CGRect,
        globalRect: CGRect,
        displayScale: CGFloat
    ) {
        self.displayID = displayID
        self.rectInCaptureSpace = rectInCaptureSpace
        self.globalRect = globalRect
        self.displayScale = displayScale
    }
}

/// 遮罩出现之前取得的不可变整屏快照。
///
/// 后续窗口选择和自由拖选都只裁剪这张图片，不会在 mouseUp 后再次请求系统截图。
/// 它只存在于当前截图会话的内存中；选区/编辑窗口关闭后，最后一个引用释放即销毁。
public struct FrozenScreenFrame: Sendable {
    public let target: ScreenCaptureTarget
    public let image: RasterImage

    public init(target: ScreenCaptureTarget, image: RasterImage) {
        self.target = target
        self.image = image
    }

    /// 从冻结整屏图中做纯内存裁剪。选择器和编辑器都复用这一个坐标转换实现，
    /// 因而调整选区时不需要再次请求 ScreenCaptureKit。
    /// Java 对照：这是不可变值对象上的无副作用计算，类似 domain value method。
    public func cropped(to selection: ScreenSelection) throws -> RasterImage {
        guard selection.displayID == target.displayID else {
            throw AppFailure.invalidData("选区与冻结屏幕不属于同一显示器")
        }

        let source = image.cgImage
        let logicalSize = target.globalRect.size
        guard logicalSize.width > 0, logicalSize.height > 0 else {
            throw AppFailure.invalidData("冻结屏幕尺寸无效")
        }

        // 用实际位图尺寸除以逻辑尺寸得到倍率，不能假定所有显示器固定为 Retina 的 2 倍。
        let scaleX = CGFloat(source.width) / logicalSize.width
        let scaleY = CGFloat(source.height) / logicalSize.height
        let logicalRect = selection.rectInDisplay.standardized
        // 下边界向下取整、上边界向上取整，覆盖完整选区；例如 0.5 pt 在 2 倍屏上恰好是 1 px。
        let requestedPixels = CGRect(
            x: floor(logicalRect.minX * scaleX),
            y: floor(logicalRect.minY * scaleY),
            width: ceil(logicalRect.maxX * scaleX) - floor(logicalRect.minX * scaleX),
            height: ceil(logicalRect.maxY * scaleY) - floor(logicalRect.minY * scaleY)
        )
        let imageBounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        // intersection 裁到图片边界；integral 得到整数像素框，cropping 返回新 CGImage 引用。
        let cropRect = requestedPixels.intersection(imageBounds).integral
        guard cropRect.width >= 1,
              cropRect.height >= 1,
              let cropped = source.cropping(to: cropRect) else {
            throw AppFailure.invalidData("选区超出冻结屏幕范围")
        }
        return RasterImage(cgImage: cropped, createdAt: image.createdAt)
    }
}

/// 选区坐标统一使用“当前显示器内部、左上角为原点”的逻辑点坐标。
///
/// AppKit 的全局坐标原点在左下，ScreenCaptureKit 的 sourceRect 使用显示器
/// 逻辑坐标。把转换集中在选区适配器内，可避免多显示器上下排列时出现 Y 轴错误。
public struct ScreenSelection: Sendable, Equatable {
    public let displayID: UInt32
    /// 单击窗口时保存 WindowServer 标识；nil 表示自由选区。当前裁剪仍只读取冻结图。
    public let windowID: UInt32?
    public let rectInDisplay: CGRect
    public let displayScale: CGFloat
    /// AppKit 全局屏幕坐标（左下角为原点），仅用于把截图编辑浮层放回原选区。
    public let globalRect: CGRect

    public init(
        displayID: UInt32,
        windowID: UInt32?,
        rectInDisplay: CGRect,
        displayScale: CGFloat,
        globalRect: CGRect
    ) {
        self.displayID = displayID
        self.windowID = windowID
        self.rectInDisplay = rectInDisplay
        self.displayScale = displayScale
        self.globalRect = globalRect
    }
}

/// 截图位图及其屏幕位置。业务流程返回这个整体，避免平台层重新猜测多屏坐标。
public struct CapturedRegion: Sendable {
    public let image: RasterImage
    public let selection: ScreenSelection
    /// 编辑器在用户选中第一个工具前允许继续调整选区，因此需要继续持有冻结整屏。
    /// 这里只增加一个 CGImage 引用，不会复制整屏像素；会话关闭后自动释放。
    public let frozenFrame: FrozenScreenFrame

    public init(
        image: RasterImage,
        selection: ScreenSelection,
        frozenFrame: FrozenScreenFrame
    ) {
        self.image = image
        self.selection = selection
        self.frozenFrame = frozenFrame
    }
}

/// 截图选区端口，作用类似 Java interface。
///
/// `AnyObject` 限制实现必须是 class；`@MainActor` 又规定所有调用都经过 UI 主隔离域。
/// 因此协议本身同时表达了“对象语义”和“线程约束”。
@MainActor
public protocol ScreenRegionSelecting: AnyObject {
    /// 在创建全屏遮罩前完成权限检查，保证平台层可以先取得稳定的窗口快照。
    func ensureScreenCapturePermission() throws

    /// 根据快捷键触发时的鼠标位置确定本次只冻结哪一块显示器。
    func currentCaptureTarget() throws -> ScreenCaptureTarget

    /// 在已经冻结的显示器图片上完成窗口命中或自由拖选。
    func selectRegion(in frozenFrame: FrozenScreenFrame) async throws -> ScreenSelection

    /// 外部快捷键的紧急取消入口。实现必须同时关闭面板并恢复尚未完成的 continuation。
    func cancelSelection()

    /// 下一阶段 UI 接管选区遮罩以后，清理没有被接管的选择阶段资源。
    func dismissSelectionOverlay()
}

/// 像素捕获端口不依赖 AppKit，实际实现可以是 actor。
/// `Sendable` 表示实现可安全地跨 Task/actor 边界引用，类似由编译器检查的线程安全契约。
public protocol ScreenCapturing: Sendable {
    /// 遮罩出现之前只调用一次系统截图，返回当前显示器的完整不可变图像。
    func freeze(target: ScreenCaptureTarget) async throws -> FrozenScreenFrame

    /// 从冻结图像中进行纯内存裁剪；不再访问 WindowServer 或 ScreenCaptureKit XPC。
    func crop(
        selection: ScreenSelection,
        from frozenFrame: FrozenScreenFrame
    ) async throws -> RasterImage
}
