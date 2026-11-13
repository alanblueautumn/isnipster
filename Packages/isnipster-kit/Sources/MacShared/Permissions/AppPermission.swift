// 阅读路线
// 统一屏幕捕获与自动粘贴的权限查询、请求、设置跳转；调用方决定何时展示提示。
// TCC 授权由系统和用户控制，沙盒 entitlement 是签名能力，两者不能互相替代。
// 官方参考（系统事件与屏幕访问）：https://developer.apple.com/documentation/coregraphics

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 项目权限的统一入口。TCC（Transparency, Consent, and Control）由 macOS 在系统设置中保存，
/// 应用只能“查询 / 请求 / 跳转设置”，没有代码能替用户授予权限；因此预检通过也不等于后续系统操作必然成功。
public enum AppPermission: Sendable, Hashable {
    case screenCapture
    case directPaste

    public var isGranted: Bool {
        switch self {
        case .screenCapture:
            // CoreGraphics 的预检不会弹窗，适合刷新 UI 状态；调用时仍可能因系统策略失败。
            CGPreflightScreenCaptureAccess()
        case .directPaste:
            // 模拟 Cmd-V 既需要发送键盘事件的授权，也可能受“辅助功能”信任状态限制。
            CGPreflightPostEventAccess() || AXIsProcessTrusted()
        }
    }

    public var denialMessage: String {
        switch self {
        case .screenCapture:
            AppText.text("截图被系统拒绝，请检查录屏授权后重试。")
        case .directPaste:
            AppText.text("自动粘贴需要授权，请检查辅助功能设置后重试。")
        }
    }

    @MainActor
    @discardableResult
    public func requestAccess() -> Bool {
        // false 仅表示尚未授权，系统询问可能仍在显示，不能据此自动打开设置。
        guard !isGranted else { return true }
        switch self {
        case .screenCapture:
            // CGRequestScreenCaptureAccess 是触发系统录屏授权流程的 CoreGraphics API；它不提供 await 回调。
            return CGRequestScreenCaptureAccess()
        case .directPaste:
            // 发送键盘事件的授权弹窗同样由系统管理，返回后重新读取状态，而不是相信请求函数的返回值。
            _ = CGRequestPostEventAccess()
            return isGranted
        }
    }

    @MainActor
    public func openSystemSettings() {
        // x-apple.systempreferences 是 Apple 定义的深链，不是网页 URL；NSWorkspace 交给系统打开对应设置页。
        let pane = self == .screenCapture ? "Privacy_ScreenCapture" : "Privacy_Accessibility"
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        // 交给 macOS 选择 URL 对应的处理程序；可以打开网页或系统设置深链，不是应用内 HTTP 请求。
        NSWorkspace.shared.open(url)
    }
}

public struct AppPermissionStatus: Sendable {
    public let permission: AppPermission
    public let isGranted: Bool

    public static func current(for permission: AppPermission) -> Self {
        Self(
            permission: permission,
            isGranted: permission.isGranted
        )
    }
}
