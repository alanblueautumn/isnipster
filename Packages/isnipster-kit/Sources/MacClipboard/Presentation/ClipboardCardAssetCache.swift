import MacShared
import MacPreferences
// 阅读路线
// 缓存卡片缩略图与来源应用图标，避免 body 重算或横向滚动时反复解码。
// 缓存只是展示加速；条目的实际 PNG 和来源标识仍由 ClipboardEntry 提供。
// 官方参考（NSCache 可丢弃缓存）：https://developer.apple.com/documentation/foundation/nscache

import AppKit
import ImageIO

/// 缓存卡片预览图和来源应用图标，减少滚动时的重复解码。
@MainActor
enum ClipboardCardAssetCache {
    // NSCache 可在内存压力下驱逐对象，适合可重建的缩略图；limit 是缓存策略，不是可靠的业务存储上限。
    private static let previewImages: NSCache<NSUUID, NSImage> = {
        let cache = NSCache<NSUUID, NSImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()
    private static let applicationIcons: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 64
        return cache
    }()

    /// 先按记录 UUID 查缓存，未命中时用 ImageIO 生成最大边受限的缩略图并按解码字节计成本。
    static func image(for id: UUID, data: Data) -> NSImage? {
        let key = id as NSUUID
        if let cached = previewImages.object(forKey: key) {
            return cached
        }

        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false
        ]
        // ImageIO 从编码字节创建图片源；读取元数据不等于已经完整解码所有像素。
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceShouldCacheImmediately: true
        ]
        // 让 ImageIO 直接生成受尺寸约束的缩略图；预览不需要先创建完整大小的 NSImage。
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }

        let image = NSImage(
            cgImage: thumbnail,
            size: NSSize(
                width: CGFloat(thumbnail.width),
                height: CGFloat(thumbnail.height)
            )
        )
        // 缓存成本按解码后的行字节数乘高度估算；压缩后的 PNG 字节数无法反映展示内存。
        let decodedByteCost = thumbnail.bytesPerRow * thumbnail.height
        previewImages.setObject(image, forKey: key, cost: decodedByteCost)
        return image
    }

    /// 由 bundle ID 查本机应用位置并取图标；应用已卸载或无法定位时返回 nil 让界面降级。
    static func applicationIcon(bundleIdentifier: String) -> NSImage? {
        let key = bundleIdentifier as NSString
        if let cached = applicationIcons.object(forKey: key) {
            return cached
        }
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: bundleIdentifier
        ) else {
            return nil
        }
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        applicationIcons.setObject(icon, forKey: key)
        return icon
    }
}
