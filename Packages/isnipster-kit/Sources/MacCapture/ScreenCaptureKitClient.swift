import MacShared
import MacScreenshotSupport
// 阅读路线
// freeze 从系统获取一张整屏图；crop 只操作内存。新系统用矩形截图，15.0/15.1 用显示器过滤器。
// if #available 是运行时能力分支；异步系统 API 不等于立即响应 Task.cancel，必须在返回后重新检查。
// 官方参考（ScreenCaptureKit 单帧截图）：https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager

// 框架分工：ScreenCaptureKit 向 WindowServer 请求屏幕帧；CoreGraphics 提供位图和坐标类型；
// CoreVideo 提供跨媒体 API 共用的像素格式常量。Feature 层只看到 ScreenCapturing 协议，不依赖这些系统框架。
import CaptureFeature
import CoreGraphics
import CoreVideo
import Foundation
import ScreenCaptureKit
import iSnipsterCore

/// 先冻结鼠标所在屏幕，再从同一张图片中裁剪选区。
/// 系统请求直接使用原生 async 接口；取消后的界面恢复由操作入口负责。
public struct ScreenCaptureKitClient: ScreenCapturing {
    public init() {}

    /// 向系统请求目标显示器的帧，并包装成不可变会话输入；系统错误在边界转换为 AppFailure。
    public func freeze(target: ScreenCaptureTarget) async throws -> FrozenScreenFrame {
        // Task.checkCancellation 不会主动终止系统 XPC 请求；它是协作式检查点，确保取消后不把迟到图片交给 UI。
        try Task.checkCancellation()
        do {
            // CGImage 是不可变像素缓冲的轻量引用，不等于 NSImage（后者还带 AppKit 展示语义）。
            let image: CGImage
            if #available(macOS 15.2, *) {
                // SCScreenshotManager 是 ScreenCaptureKit 提供的单帧截图 API；系统在这里完成授权和跨进程捕获。
                image = try await SCScreenshotManager.captureImage(in: target.rectInCaptureSpace)
            } else {
                image = try await captureDisplayUsingFilter(target: target)
            }
            // 系统请求不一定响应取消，返回后必须先检查再交付图片。
            try Task.checkCancellation()
            return FrozenScreenFrame(target: target, image: RasterImage(cgImage: image))
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if let failure = error as? AppFailure { throw failure }
            throw Self.captureFailure(error, message: "截图失败：%@")
        }
    }

    /// 遵守异步端口签名，但内部执行纯内存裁剪；async 并不代表每个方法内部都有 await。
    public func crop(
        selection: ScreenSelection,
        from frozenFrame: FrozenScreenFrame
    ) async throws -> RasterImage {
        try Task.checkCancellation()
        return try frozenFrame.cropped(to: selection)
    }

    /// macOS 15.0/15.1 先查找目标显示器，再用过滤器截取单帧。
    private func captureDisplayUsingFilter(target: ScreenCaptureTarget) async throws -> CGImage {
        // SCShareableContent 是系统可捕获显示器/窗口的快照；不要长期缓存，因为显示器和窗口会随时变化。
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            throw Self.captureFailure(error, message: "无法读取屏幕内容：%@")
        }
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == target.displayID }) else {
            throw AppFailure.unavailable(AppText.text("截图显示器已经断开"))
        }

        // 即使只截一帧，旧系统路径仍借用流配置描述像素格式、是否包含光标和输出尺寸。
        let configuration = SCStreamConfiguration()
        // 32BGRA 表示每像素 4 字节，内存通道顺序为蓝、绿、红、透明度；它是 macOS 图形管线常用格式。
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        // 鼠标由选区 UI 自己绘制；若把系统光标录入冻结图，用户移动时会看到两只光标。
        configuration.showsCursor = false
        // ScreenCaptureKit 需要像素尺寸，而 target.globalRect 是 AppKit point；ceil 避免 Retina 末端丢失半个 point 对应的像素。
        configuration.width = max(1, Int(ceil(target.globalRect.width * target.displayScale)))
        configuration.height = max(1, Int(ceil(target.globalRect.height * target.displayScale)))

        // 遮罩尚未出现，保留所有可见窗口，包括本应用的翻译框和贴图。
        // SCContentFilter 定义捕获范围与排除项；空数组表示不特意排除本应用窗口。
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
    }

    /// 先按 NSError 的域和代码识别授权拒绝，其余错误保留系统原因并转换为业务失败。
    private static func captureFailure(_ error: Error, message: String) -> AppFailure {
        // NSError 是 Foundation 的错误类；domain + code 组合用于区分系统框架的错误种类。
        // Swift Error 没有要求所有错误都声明枚举 case，因此在平台边界转换为本项目 AppFailure。
        let systemError = error as NSError
        if systemError.domain == SCStreamErrorDomain,
           systemError.code == SCStreamError.Code.userDeclined.rawValue {
            AppDiagnostics.failure(OperationFailure(category: .permission, stage: "capture.system",
                message: AppPermission.screenCapture.denialMessage, underlying: error), stage: "capture.system")
            return .permissionDenied(AppPermission.screenCapture.denialMessage)
        }
        AppDiagnostics.failure(OperationFailure(category: .systemService, stage: "capture.system",
            message: error.localizedDescription, underlying: error), stage: "capture.system")
        return .operationFailed(AppText.format(message, error.localizedDescription))
    }
}
