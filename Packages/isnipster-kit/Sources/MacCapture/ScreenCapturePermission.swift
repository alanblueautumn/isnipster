import MacShared
import MacScreenshotSupport
// 阅读路线
// 截图入口调用这里把权限预检结果转成 AppFailure；请求授权和展示提示由应用层协调。
// 权限查询不等于授权，也不保证后面的系统截图必然成功。
// 官方参考（屏幕捕获权限预检）：https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess()

import iSnipsterCore

/// 屏幕录制权限的统一处理。
enum ScreenCapturePermission {
    static func requireAccess() throws {
        if AppPermission.screenCapture.isGranted { return }
        throw AppFailure.permissionDenied(AppPermission.screenCapture.denialMessage)
    }
}





