import MacShared
import MacScreenshotSupport
import MacTranslation
// 阅读路线
// 实现 EditorPreferencesStoring：将配置编码为 Data 写入 UserDefaults，读取失败则使用默认配置。
// 存储类只处理笔触偏好，不拥有 ImageDocument，因此不会顺带序列化截图和撤销栈。
// 官方参考（UserDefaults 小型偏好存储）：https://developer.apple.com/documentation/foundation/userdefaults

import Foundation
import ImageEditorFeature

/// 使用系统偏好设置保存截图工具栏配置。
///
/// UserDefaults 最终只写入一个很小的 JSON Data。它不接收 ImageDocument，因而从类型层面
/// 就无法访问截图位图、标注内容、OCR 结果或剪贴板历史。
/// Java 对照：这是 EditorPreferencesStoring 的基础设施层 Repository 实现。
@MainActor
public final class UserDefaultsEditorPreferencesStore: EditorPreferencesStoring {
    private static let storageKey = "isnipster.editorPreferences"

    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 恢复偏好 DTO；缺失或解码失败时返回默认配置，调用方无需处理损坏的原始字节。
    public func load() -> EditorPreferences {
        guard
            let data = defaults.data(forKey: Self.storageKey),
            let preferences = try? decoder.decode(EditorPreferences.self, from: data)
        else {
            // 第一次启动或配置损坏时使用产品默认值，不影响截图主流程。
            return EditorPreferences()
        }
        return preferences
    }

    /// 编码当前偏好并写入约定键；接口不接收图片，所以不会通过此路径保存截图内容。
    public func save(_ preferences: EditorPreferences) {
        // 配置编码失败不应该阻断截图；下一次启动退回默认值即可。
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: Self.storageKey)

        // 不调用 synchronize()：UserDefaults 会自行合并并落盘，强制同步反而会阻塞 UI。
    }
}
