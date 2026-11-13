# iSnipster

[官方网站](https://www.isnipster.cn/) · [GitHub 仓库](https://github.com/alanblueautumn/isnipster)

一款 macOS 截图与效率工具，集成截图标注、OCR 文字识别、截图翻译、文本翻译和剪贴板历史管理。

## 获取官方安装包

不想配置开发环境？可以通过闲鱼购买官方预编译 DMG 安装包，下载后直接安装使用。

**[前往闲鱼购买 iSnipster 官方安装包 · ¥1.99](https://m.tb.cn/h.8FAJyEN?tk=lGycTOggRlS)**

- **系统要求**：macOS 15.0 及以上，仅支持 Mac。
- **交付方式**：付款后按闲鱼商品说明获取安装包下载链接和安装说明。
- **购买内容**：商品页面所标注版本的官方预编译 DMG 安装包；交付时间和更新范围以商品说明为准。
- **使用说明**：截图需要授予屏幕录制权限；系统翻译可能需要下载语言包，在线翻译源需要联网。

本仓库不提供 DMG 下载镜像，官方安装包通过上述闲鱼商品交付。

## 资源配置说明

配置目录：`isnipster-app/Resources`

## Assets.xcassets

保存应用图标和图片资源，Xcode 构建时会将其编译进应用。

### Assets.xcassets/Contents.json

- `info.author`：资源目录生成工具，当前为 `xcode`。
- `info.version`：资源目录格式版本，当前为 `1`。

### AppIcon.appiconset/Contents.json

定义不同尺寸的 macOS 应用图标。

- `images`：图标规格列表。
- `filename`：图标 PNG 文件名。
- `idiom`：目标平台，`mac` 表示 macOS。
- `size`：图标逻辑尺寸。
- `scale`：屏幕缩放倍率，`1x` 为普通分辨率，`2x` 为 Retina。
- `info.author`：配置生成工具，当前为 `xcode`。
- `info.version`：配置格式版本，当前为 `1`。

项目使用 `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` 指定该图标集。

## Info.plist

配置应用身份、版本和系统行为。`$(...)` 会在构建时由 Xcode Build Settings 替换。

- `CFBundleDevelopmentRegion`：默认开发语言和地区，当前为 `zh_CN`。
- `CFBundleDisplayName`：系统显示的应用名称，取自 `APP_DISPLAY_NAME`。
- `CFBundleExecutable`：主可执行文件名称，取自 `EXECUTABLE_NAME`。
- `CFBundleIdentifier`：应用唯一标识，取自 `PRODUCT_BUNDLE_IDENTIFIER`。
- `CFBundleInfoDictionaryVersion`：Info.plist 格式版本。
- `CFBundleName`：应用内部名称，取自 `APP_DISPLAY_NAME`。
- `CFBundlePackageType`：应用包类型，`APPL` 表示应用程序。
- `CFBundleShortVersionString`：用户可见版本号，取自 `MARKETING_VERSION`。
- `CFBundleVersion`：构建号，取自 `CURRENT_PROJECT_VERSION`。
- `LSApplicationCategoryType`：App Store 分类，当前为工具类应用。
- `LSMinimumSystemVersion`：最低支持的 macOS 版本。
- `LSUIElement`：设为 `true` 时作为菜单栏应用运行，默认不显示 Dock 图标。
- `NSHighResolutionCapable`：设为 `true` 时支持 Retina 高分辨率显示。
- `NSHumanReadableCopyright`：版权文本。
- `NSPrincipalClass`：应用主类，当前为 `NSApplication`。
- `NSScreenCaptureUsageDescription`：系统申请屏幕录制权限时显示的用途说明。

### Debug 配置

- 应用名称：`iSnipster Dev`
- Bundle ID：`com.isnipster.app.debug`
- 应用包：`iSnipster Dev.app`

### Release 配置

- 应用名称：`iSnipster`
- Bundle ID：`com.isnipster.app`
- 应用包：`iSnipster.app`

## iSnipster.entitlements

配置写入代码签名的沙盒能力。

- `com.apple.security.app-sandbox`：开启 App Sandbox。
- `com.apple.security.files.user-selected.read-write`：允许读写用户通过文件选择器选择的文件。
- `com.apple.security.network.client`：允许应用主动访问网络。

屏幕录制和辅助功能属于 macOS TCC 动态授权，不在该文件中配置。

## PrivacyInfo.xcprivacy

提交 App Store 使用的隐私清单。

- `NSPrivacyAccessedAPITypes`：使用的 Required Reason API 列表。
- `NSPrivacyAccessedAPIType`：API 类别，当前声明使用 `UserDefaults`。
- `NSPrivacyAccessedAPITypeReasons`：使用该 API 的 Apple 原因代码，当前为 `CA92.1`。
- `NSPrivacyCollectedDataTypes`：应用收集的数据类型列表。
- `NSPrivacyCollectedDataType`：数据类型，当前为其他用户内容。
- `NSPrivacyCollectedDataTypeLinked`：数据是否关联用户身份，当前为 `false`。
- `NSPrivacyCollectedDataTypePurposes`：数据用途，当前为提供应用功能。
- `NSPrivacyCollectedDataTypeTracking`：数据是否用于追踪，当前为 `false`。
- `NSPrivacyTracking`：是否进行跨应用或网站追踪，当前为 `false`。
- `NSPrivacyTrackingDomains`：追踪域名列表，当前为空。

## .DS_Store

Finder 自动生成的目录显示信息，不属于应用配置，不应提交到 Git。
