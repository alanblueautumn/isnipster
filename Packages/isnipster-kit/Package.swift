// swift-tools-version: 6.0

// 阅读路线
// 从这里看模块依赖，再读 iSnipsterApp → CompositionRoot。App 是可运行入口，Package 提供可导入的库。
// Feature 保存用例和数据契约；MacPlatform 连接系统服务；具体对象由 App 层组装。
// 官方参考（SwiftPM 清单）：https://docs.swift.org/package-manager/PackageDescription/PackageDescription.html

import PackageDescription

// Swift Package Manager 的模块图，可类比 Maven 多模块项目的父 pom。
// 每个 target 都会形成独立 Swift Module；Feature 依赖业务契约，Mac 模块实现系统适配。
// 平台功能之间通过显式依赖建立边界，领域层不依赖 UI 或系统实现。
// SwiftPM 自动包含 Sources/<target> 下的 Swift 文件；新增业务/视图文件无需逐个登记。
let package = Package(
    name: "iSnipsterKit",
    defaultLocalization: "zh-Hans",
    // 最低系统版本约束库的部署范围；它不等于本机 SDK 版本，也不会自动授权屏幕录制等系统权限。
    platforms: [.macOS(.v15)],
    // product 是对外导出的库；target 是参与编译的模块，可类比 Maven 发布产物与子模块的区别。
    products: [
        .library(name: "iSnipsterCore", targets: ["iSnipsterCore"]),
        .library(name: "RecognitionFeature", targets: ["RecognitionFeature"]),
        .library(name: "CaptureFeature", targets: ["CaptureFeature"]),
        .library(name: "ImageEditorFeature", targets: ["ImageEditorFeature"]),
        .library(name: "ImageTranslationFeature", targets: ["ImageTranslationFeature"]),
        .library(name: "TextTranslationFeature", targets: ["TextTranslationFeature"]),
        .library(name: "ClipboardFeature", targets: ["ClipboardFeature"]),
        .library(name: "ColorPickerFeature", targets: ["ColorPickerFeature"]),
        .library(name: "MacPlatform", targets: ["MacPlatform"])
    ],
    targets: [
        // iSnipsterCore：所有 Feature 都可复用的最小值对象与错误定义。
        .target(name: "iSnipsterCore", path: "Sources/isnipster-core"),
        // Feature：业务模型、协议和流程编排，不 import AppKit/ScreenCaptureKit。
        .target(name: "CaptureFeature", dependencies: ["iSnipsterCore"]),
        .target(name: "ImageEditorFeature", dependencies: ["iSnipsterCore"]),
        .target(name: "ImageTranslationFeature", dependencies: ["iSnipsterCore", "RecognitionFeature", "TextTranslationFeature"]),
        .target(name: "RecognitionFeature", dependencies: ["iSnipsterCore"]),
        .target(name: "TextTranslationFeature", dependencies: ["iSnipsterCore"]),
        .target(name: "ClipboardFeature", dependencies: ["iSnipsterCore"]),
        .target(name: "ColorPickerFeature", dependencies: ["iSnipsterCore"]),
        // 平台功能分别编译；MacPlatform 只向应用组装层导出入口。
        .target(name: "MacShared", dependencies: ["iSnipsterCore"], resources: [.process("Resources")]),
        .target(name: "MacPreferences", dependencies: ["iSnipsterCore", "ClipboardFeature", "TextTranslationFeature"]),
        .target(name: "MacScreenshotSupport", dependencies: ["MacShared", "CaptureFeature", "ColorPickerFeature"]),
        .target(name: "MacCapture", dependencies: ["MacShared", "MacScreenshotSupport", "iSnipsterCore", "CaptureFeature", "ColorPickerFeature"]),
        .target(name: "MacRecognition", dependencies: ["MacShared", "iSnipsterCore", "RecognitionFeature"]),
        .target(name: "MacImageTranslation", dependencies: ["MacShared", "iSnipsterCore", "ImageTranslationFeature"]),
        .target(name: "MacTranslation", dependencies: ["MacShared", "iSnipsterCore", "TextTranslationFeature"]),
        .target(name: "MacTextTranslation", dependencies: ["MacShared", "MacPreferences", "MacTranslation", "iSnipsterCore", "TextTranslationFeature", "ClipboardFeature"]),
        .target(name: "MacClipboard", dependencies: ["MacShared", "MacPreferences", "iSnipsterCore", "ClipboardFeature"]),
        .target(name: "MacImageEditor", dependencies: ["MacShared", "MacScreenshotSupport", "MacTranslation", "iSnipsterCore", "TextTranslationFeature", "CaptureFeature", "ImageEditorFeature", "ImageTranslationFeature", "RecognitionFeature", "ClipboardFeature", "ColorPickerFeature"]),
        .target(name: "MacPlatform", dependencies: ["MacShared", "MacPreferences", "MacScreenshotSupport", "MacCapture", "MacRecognition", "MacImageTranslation", "MacTranslation", "MacTextTranslation", "MacClipboard", "MacImageEditor"])
    ],
    // 启用 Swift 6 语言模式，包括更严格的并发隔离检查；这与 swift-tools-version 的清单 API 版本不同。
    swiftLanguageModes: [.v6]
)
