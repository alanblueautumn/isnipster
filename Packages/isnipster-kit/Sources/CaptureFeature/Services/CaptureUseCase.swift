// 阅读路线
// 截图主流程：检查权限 → 确定显示器 → 冻结整屏 → 等用户选择 → 内存裁剪 → 返回编辑器。
// await 是允许挂起的位置；取消是协作式的，所以返回图片后仍要检查，不能把过期结果展示出来。
// 官方参考（Swift 并发与取消）：https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/

import iSnipsterCore

/// 截图流程编排。UI 选择必须在 MainActor，真正截图由适配器异步完成。
///
/// Java 对照：这是 Application Service，只依赖两个接口，不知道 NSPanel、CGImage
/// 或 ScreenCaptureKit。`@MainActor` 不是一把普通锁，而是编译器检查的 UI 执行域。
@MainActor
public final class CaptureUseCase {
    private let selector: any ScreenRegionSelecting
    private let capturer: any ScreenCapturing

    // any ScreenRegionSelecting 是协议存在类型，像 Java 接口引用；some 则隐藏一个固定的具体类型，二者不同。
    public init(selector: any ScreenRegionSelecting, capturer: any ScreenCapturing) {
        self.selector = selector
        self.capturer = capturer
    }

    public func captureArea(
        onFrozen: @MainActor () -> Void = {}
    ) async throws -> CapturedRegion {
        try Task.checkCancellation()
        // 每次流程只请求一张系统截图：先确定鼠标所在屏幕并冻结整屏，再显示选区 UI。
        // Java 对照：frozenFrame 类似一次请求内的 immutable request context；后面的
        // 选择、裁剪和编辑都读取它，不再重新访问外部系统状态。
        try selector.ensureScreenCapturePermission()
        let target = try selector.currentCaptureTarget()
        let frozenFrame = try await capturer.freeze(target: target)
        try Task.checkCancellation()

        // 这是截图流程唯一允许产生可见 UI 副作用的边界。调用方只有在系统画面已经
        // 冻结后，才能切换光标、暂停面板收起或注册选区阶段的交互。
        // frozenFrame 保存系统实际返回的那一帧；它不是对快捷键发生时刻的同步采样。
        // 调用注入的同步闭包，类似 Runnable.run；闭包的 MainActor 标注要求与本方法处于同一隔离域。
        onFrozen()

        // Swift 的 let 是单次赋值。这里先声明、再在 do 中初始化，成功后仍保持不可变。
        let selection: ScreenSelection
        do {
            selection = try await selector.selectRegion(in: frozenFrame)
            try Task.checkCancellation()
        } catch {
            // Selector 会同步关闭所有面板。方法返回后 frozenFrame 的最后一个业务引用
            // 也会释放，不需要额外维护一个容易遗忘的“prepared capture”全局状态。
            // 这里只传播原错误，不增加补偿操作；是否关闭面板由 selector 的完成/取消路径负责。
            throw error
        }

        do {
            // 窗口和自由选区都从冻结图裁剪。mouseUp 后没有第二次系统截图请求，
            // 因此最终图片严格等于用户在遮罩中看到的那一帧。
            let image = try await capturer.crop(selection: selection, from: frozenFrame)
            try Task.checkCancellation()
            return CapturedRegion(
                image: image,
                selection: selection,
                frozenFrame: frozenFrame
            )
        } catch {
            // 主动取消已由入口关闭遮罩；旧任务恢复时不能清理新会话的面板。
            try Task.checkCancellation()
            // 捕获失败时不会进入展示阶段，必须在这里主动清理仍保留的选区遮罩。
            selector.dismissSelectionOverlay()
            throw error
        }
    }

    /// 编辑器完成遮罩所有权接管后，清理没有被接管的兜底资源。
    /// 具体 AppKit 实现复用同一批 NSPanel，因此这里不会关闭正在显示的编辑遮罩。
    public func finishPresentation() {
        selector.dismissSelectionOverlay()
    }

    /// 截图快捷键在选区已经打开时再次触发，会走这里作为独立逃生通道。
    public func cancelCapture() {
        selector.cancelSelection()
    }
}
