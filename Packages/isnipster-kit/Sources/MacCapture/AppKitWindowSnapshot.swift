import MacShared
import MacScreenshotSupport
// 阅读路线
// 先读系统窗口列表并过滤，再把 Quartz 坐标转为 AppKit 坐标；鼠标移动只查这个数组。
// 类似先收集 DOM 矩形再做命中；这是窗口几何快照，与冻结图像不是同一时刻的原子数据。
// 官方参考（Core Graphics 窗口与显示器）：https://developer.apple.com/documentation/coregraphics

import AppKit
import CoreGraphics
import Foundation

/// 进入截图模式时对当前可见窗口做一次轻量几何快照。
///
/// 这里读取窗口层级、进程、标题和边界来过滤候选，不读取窗口像素或正文。鼠标移动期间仅在
/// 本地数组中做矩形命中，避免高频调用 ScreenCaptureKit 或持续分配大对象。
struct AppKitWindowSnapshot {
    /// 可参与选区命中的单个窗口几何信息。
    struct WindowHit {
        let id: CGWindowID
        let globalRect: CGRect
    }

    private let windowsFrontToBack: [WindowHit]

    static let empty = Self(windowsFrontToBack: [])

    static func capture(excludingProcessID: pid_t = ProcessInfo.processInfo.processIdentifier) -> Self {
        // CGWindowListCopyWindowInfo 是 Core Graphics 的 C API，返回 CFArray/字典；
        // `as?` 是安全类型转换，失败时得到 nil，不会像 Java 强转那样抛异常。
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfos = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else {
            return Self(windowsFrontToBack: [])
        }

        // Quartz 窗口坐标以主屏左上为原点；AppKit 全局坐标以主屏左下为原点。
        // 只在生成快照时转换一次，后续命中和选区逻辑全部统一使用 AppKit 坐标。
        let appKitReferenceY = NSScreen.screens.first?.frame.maxY ?? 0
        let visibleDesktop = NSScreen.screens.reduce(CGRect.null) { partial, screen in
            partial.union(screen.frame)
        }

        // compactMap 类似 Java Stream.map + filter(nonNull)：闭包返回 nil 的项会被丢弃。
        let windows = windowInfos.compactMap { info -> WindowHit? in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            guard ownerPID != excludingProcessID else { return nil }

            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            let windowName = info[kCGWindowName as String] as? String ?? ""

            guard let windowNumber = info[kCGWindowNumber as String] as? NSNumber else {
                return nil
            }

            // 普通应用窗口位于 layer 0；菜单、光标、Dock 特效等不应成为截图候选。
            let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1
            guard layer == 0 else { return nil }

            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.01,
                  let dictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let quartzRect = CGRect(dictionaryRepresentation: dictionary),
                  quartzRect.width >= 20,
                  quartzRect.height >= 20 else {
                return nil
            }

            let appKitRect = CGRect(
                x: quartzRect.minX,
                y: appKitReferenceY - quartzRect.maxY,
                width: quartzRect.width,
                height: quartzRect.height
            ).integral
            guard appKitRect.intersects(visibleDesktop) else { return nil }
            guard !Self.isDesktopSurface(
                ownerPID: ownerPID,
                ownerName: ownerName,
                windowName: windowName,
                rect: appKitRect
            ) else { return nil }
            return WindowHit(
                id: CGWindowID(windowNumber.uint32Value),
                globalRect: appKitRect
            )
        }

        // CGWindowListCopyWindowInfo 已按从前到后的层级返回，必须保留原始顺序。
        return Self(windowsFrontToBack: windows)
    }

    func frontmostWindow(at globalPoint: CGPoint) -> WindowHit? {
        // first(where:) 返回 Optional<WindowHit>；调用方必须显式处理“没有命中”。
        windowsFrontToBack.first { $0.globalRect.contains(globalPoint) }
    }

    /// 过滤系统桌面承载窗口，让桌面空白处由选区层明确走整屏截图逻辑。
    private static func isDesktopSurface(
        ownerPID: pid_t?,
        ownerName: String,
        windowName: String,
        rect: CGRect
    ) -> Bool {
        let ownerBundleIdentifier = ownerPID.flatMap {
            NSRunningApplication(processIdentifier: $0)?.bundleIdentifier
        }
        let desktopOwners: Set<String> = [
            "com.apple.finder",
            "com.apple.dock",
            "com.apple.WindowManager"
        ]
        let isDesktopOwner = ownerBundleIdentifier.map(desktopOwners.contains) == true
            || ["Finder", "Dock", "WindowManager"].contains(ownerName)
        let isDesktopName = windowName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || ["Desktop", "桌面"].contains(windowName)

        guard isDesktopOwner, isDesktopName else { return false }
        return NSScreen.screens.contains { screen in
            abs(rect.minX - screen.frame.minX) <= 1
                && abs(rect.minY - screen.frame.minY) <= 1
                && abs(rect.width - screen.frame.width) <= 2
                && abs(rect.height - screen.frame.height) <= 2
        }
    }
}
