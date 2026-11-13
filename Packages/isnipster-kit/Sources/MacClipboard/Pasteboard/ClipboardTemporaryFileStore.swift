import Foundation

/// 仅处理临时文件，不访问 AppKit；同步磁盘 I/O 在此 actor 上串行执行。
actor ClipboardTemporaryFileStore {
    private static let expirationInterval: TimeInterval = 24 * 60 * 60
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("isnipster-file-paste", isDirectory: true)

    func preparePNG(_ data: Data, suggestedName: String, protecting protectedURL: URL?) throws -> URL {
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        Self.cleanupExpiredFiles(in: directory, protecting: protectedURL)
        try Task.checkCancellation()
        let name = URL(fileURLWithPath: suggestedName).lastPathComponent
        let normalized = name.lowercased().hasSuffix(".png") ? name : "\(name).png"
        let url = Self.availableFileURL(in: directory, requestedName: normalized)
        do {
            try data.write(to: url, options: .atomic)
            try Task.checkCancellation()
            return url
        } catch {
            discard(url)
            throw error
        }
    }

    func discard(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// 优先保留请求文件名，已存在时追加短 UUID，避免覆盖之前复制但尚未粘贴的文件。
    private static func availableFileURL(
        in directory: URL,
        requestedName: String
    ) -> URL {
        let requestedURL = directory.appendingPathComponent(requestedName)
        guard FileManager.default.fileExists(atPath: requestedURL.path) else {
            return requestedURL
        }

        let baseName = requestedURL.deletingPathExtension().lastPathComponent
        let suffix = UUID().uuidString.prefix(6)
        return directory.appendingPathComponent("\(baseName)-\(suffix).png")
    }

    /// 只清理本功能目录中的过期普通文件；创建新文件时触发维护，而非启动常驻清理定时器。
    private static func cleanupExpiredFiles(in directory: URL, protecting protectedURL: URL?) {
        let expirationDate = Date().addingTimeInterval(-expirationInterval)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        for file in files {
            guard file != protectedURL else { continue }
            guard let values = try? file.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let modificationDate = values.contentModificationDate,
                  modificationDate < expirationDate else {
                continue
            }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
