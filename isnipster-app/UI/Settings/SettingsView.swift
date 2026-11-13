// 阅读路线
// 根设置页持有页面导航与 @AppStorage 偏好，拼装各 extension 页并执行系统设置副作用。
// UserDefaults 变化 → ClipboardSettingsSnapshot 变化 → 刷新采集策略；登录项则调用 SMAppService。
// 官方参考（登录项注册）：https://developer.apple.com/documentation/servicemanagement/smappservice

import AppKit
import ImageTranslationFeature
import MacPlatform
import ServiceManagement
import iSnipsterCore
import SwiftUI

@MainActor
enum SettingsWindowPresentation {
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        // 把闭包排到主队列稍后执行；常用于等待当前布局/焦点切换结束，不会创建后台工作线程。
        DispatchQueue.main.async {
            guard let settingsWindow = NSApp.windows.first(where: {
                $0.title == "iSnipster 设置" || $0.title == "iSnipster Settings"
            }) else {
                return
            }
            settingsWindow.title = AppText.text("iSnipster 设置")
            settingsWindow.makeKeyAndOrderFront(nil)
            // 把窗口放到前面显示，不等于激活整个应用或把某个输入控件设为 first responder。
            settingsWindow.orderFrontRegardless()
        }
    }
}

/// 设置窗口侧栏可选择的功能页面。
private enum SettingsPage: String, CaseIterable, Identifiable {
    case general
    case translation
    case clipboard
    case shortcuts
    case privacy
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: AppText.text("通用")
        case .translation: AppText.text(.translate)
        case .clipboard: AppText.text("剪贴板")
        case .shortcuts: AppText.text("快捷键")
        case .privacy: AppText.text("隐私")
        case .about: AppText.text("关于")
        }
    }

    var subtitle: String {
        switch self {
        case .general: AppText.text("管理 iSnipster 的启动行为和界面语言")
        case .translation: AppText.text("设置文本翻译目标语言与截图翻译默认语言")
        case .clipboard: AppText.text("管理剪贴板历史、内容类型与安全选项")
        case .shortcuts: AppText.text("自定义 iSnipster 的全局快捷键")
        case .privacy: AppText.text("了解数据处理、保留和删除方式")
        case .about: AppText.text("查看版本信息与应用说明")
        }
    }

    var icon: String {
        switch self {
        case .general: "sun.max"
        case .translation: "globe"
        case .clipboard: "clipboard"
        case .shortcuts: "keyboard"
        case .privacy: "hand.raised"
        case .about: "info.circle"
        }
    }

    var iconColor: Color {
        switch self {
        case .general: .gray
        case .translation: .cyan
        case .clipboard: .indigo
        case .shortcuts: Color(nsColor: .darkGray)
        case .privacy: .green
        case .about: .gray
        }
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || title.localizedCaseInsensitiveContains(query)
            || subtitle.localizedCaseInsensitiveContains(query)
    }
}

/// 汇总会触发剪贴板策略刷新的设置值，便于统一监听变化。
private struct ClipboardSettingsSnapshot: Equatable {
    let recordsHistory: Bool
    let historyLimit: Int
    let retentionDays: Int
    let clearsExpiredItems: Bool
    let recordsText: Bool
    let recordsImages: Bool
    let recordsFiles: Bool
    let recordsColors: Bool
    let removesDuplicates: Bool
}

/// 应用设置窗口的根视图，组织通用、翻译、剪贴板、快捷键和隐私页面。
struct SettingsView: View {
    // @Bindable 为 @Observable 对象生成 $属性 绑定，类似 v-model 通道；对象的创建和共享仍由外层负责。
    @Bindable var model: AppModel

    // @State 由 SwiftUI 按视图身份保留局部状态，类似 Vue ref；View 结构体重建不等于状态重置。
    @State private var selectedPage = SettingsPage.general
    @State private var searchText = ""
    @State private var navigationHistory: [SettingsPage] = [.general]
    @State private var navigationIndex = 0
    @State var launchAtLoginStatus = SMAppService.Status.notRegistered
    @State var launchAtLoginErrorMessage: String?
    @State var screenshotToolShortcuts = ScreenshotToolShortcutStore.load()
    @State var screenshotToolShortcutMessage: String?

    // @AppStorage 将偏好属性连接到 UserDefaults，并让 View 响应变化；等号后的值是未保存时的默认值。
    @AppStorage(AppPreferences.Clipboard.recordsClipboardHistory.name) var recordsClipboardHistory = AppPreferences.Clipboard.recordsClipboardHistory.defaultValue
    @AppStorage(AppPreferences.Clipboard.clipboardHistoryLimit.name) var clipboardHistoryLimit = AppPreferences.Clipboard.clipboardHistoryLimit.defaultValue
    @AppStorage(AppPreferences.Clipboard.clipboardRetentionDays.name) var clipboardRetentionDays = AppPreferences.Clipboard.clipboardRetentionDays.defaultValue
    @AppStorage(AppPreferences.Clipboard.clearsExpiredClipboardItems.name) var clearsExpiredClipboardItems = AppPreferences.Clipboard.clearsExpiredClipboardItems.defaultValue
    @AppStorage(AppPreferences.Clipboard.recordsClipboardText.name) var recordsClipboardText = AppPreferences.Clipboard.recordsClipboardText.defaultValue
    @AppStorage(AppPreferences.Clipboard.recordsClipboardImages.name) var recordsClipboardImages = AppPreferences.Clipboard.recordsClipboardImages.defaultValue
    @AppStorage(AppPreferences.Clipboard.recordsClipboardFiles.name) var recordsClipboardFiles = AppPreferences.Clipboard.recordsClipboardFiles.defaultValue
    @AppStorage(AppPreferences.Clipboard.recordsClipboardColors.name) var recordsClipboardColors = AppPreferences.Clipboard.recordsClipboardColors.defaultValue
    @AppStorage(AppPreferences.Clipboard.removesDuplicates.name) var removesDuplicates = AppPreferences.Clipboard.removesDuplicates.defaultValue
    @AppStorage(AppPreferences.Translation.screenshotTimeoutSeconds.name) var screenshotTranslationTimeoutSeconds = AppPreferences.Translation.screenshotTimeoutSeconds.defaultValue
    @AppStorage(AppPreferences.Clipboard.suppressesDirectPastePermissionPrompt.name)
    var suppressesDirectPastePermissionPrompt = false
    @AppStorage(AppUILanguage.userDefaultsKey) private var appLanguageRawValue = AppUILanguage.system.rawValue

    private var filteredPages: [SettingsPage] {
        SettingsPage.allCases.filter { $0.matches(searchText) }
    }

    var appLanguageBinding: Binding<AppUILanguage> {
        // Binding(get:set:) 将现有状态投影为控件需要的值；类似 Vue computed 的读写代理。
        Binding(
            get: {
                AppUILanguage(rawValue: appLanguageRawValue) ?? .system
            },
            set: { language in
                appLanguageRawValue = language.rawValue
                AppUILanguage.prepareForNextLaunch(language)
            }
        )
    }

    private var clipboardSettingsSnapshot: ClipboardSettingsSnapshot {
        ClipboardSettingsSnapshot(
            recordsHistory: recordsClipboardHistory,
            historyLimit: clipboardHistoryLimit,
            retentionDays: clipboardRetentionDays,
            clearsExpiredItems: clearsExpiredClipboardItems,
            recordsText: recordsClipboardText,
            recordsImages: recordsClipboardImages,
            recordsFiles: recordsClipboardFiles,
            recordsColors: recordsClipboardColors,
            removesDuplicates: removesDuplicates
        )
    }

    // body 是界面描述的计算属性，类似 Vue render；some View 隐藏具体组合类型，不是任意 Any 对象。
    var body: some View {
        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
        .frame(minWidth: 840, idealWidth: 1000, minHeight: 600, idealHeight: 700)
        // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
        .background(SettingsPalette.contentBackground)
        // 视图进入显示层级时执行，可重复触发；需要一次性语义的业务逻辑仍应由状态或服务保证。
        .onAppear {
            refreshLaunchAtLoginStatus()
            SettingsWindowPresentation.bringToFront()
        }
        // 订阅 Combine publisher 的事件，像订阅 RxJS 流；回调里更新状态后再由 SwiftUI 刷新界面。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLaunchAtLoginStatus()
        }
        // onChange 类似 Vue watch：状态变化后执行副作用；仅监听值变化，不代表每次 body 求值都会调用。
        .onChange(of: searchText) {
            guard !filteredPages.contains(selectedPage), let firstPage = filteredPages.first else {
                return
            }
            selectPage(firstPage)
        }
        .onChange(of: clipboardSettingsSnapshot) {
            model.refreshClipboardHistoryPolicy()
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                TextField(AppText.text("搜索设置"), text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
            }
            // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(SettingsPalette.searchBackground, in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 12)
            .padding(.top, 27)
            .padding(.bottom, 14)

            VStack(spacing: 4) {
                // ForEach 根据稳定身份协调子视图，类似 Vue v-for 的 :key；顺序变化不应让记录身份跟着改变。
                ForEach(filteredPages) { page in
                    Button {
                        selectPage(page)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: page.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(
                                    page.iconColor,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                                )
                            Text(page.title)
                                .font(.system(size: 14, weight: selectedPage == page ? .medium : .regular))
                            Spacer()
                        }
                        .foregroundStyle(selectedPage == page ? Color.white : Color.primary)
                        .padding(.horizontal, 13)
                        .frame(height: 36)
                        .background(
                            selectedPage == page ? Color.accentColor : Color.clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            if filteredPages.isEmpty {
                Text(AppText.text("没有匹配的设置"))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 18)
            }

            Spacer()
        }
        .frame(width: 250)
        .background(SettingsPalette.sidebarBackground)
    }

    private var content: some View {
        VStack(spacing: 0) {
            contentToolbar
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(selectedPage.subtitle)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 26)

                    pageContent
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 32)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SettingsPalette.contentBackground)
    }

    private var contentToolbar: some View {
        HStack(spacing: 14) {
            Button {
                navigateHistory(by: -1)
            } label: {
                Image(systemName: "chevron.left")
            }
            // 通过环境向子控件传递禁用状态；这是交互限制，耗时任务入口仍需要自己的重复调用防护。
            .disabled(navigationIndex == 0)

            Button {
                navigateHistory(by: 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(navigationIndex >= navigationHistory.count - 1)

            Text(selectedPage.title)
                .font(.system(size: 20, weight: .semibold))
                .padding(.leading, 6)

            Spacer()
        }
        .buttonStyle(SettingsToolbarButtonStyle())
        .padding(.leading, 26)
        .padding(.trailing, 20)
        .frame(height: 52)
        .background(SettingsPalette.toolbarBackground)
    }

    // 类似浏览器导航：从历史中间选择新页面时丢弃“前进”分支，再追加新的当前位置。
    private func selectPage(_ page: SettingsPage) {
        guard page != selectedPage else { return }
        if navigationIndex < navigationHistory.count - 1 {
            navigationHistory.removeSubrange((navigationIndex + 1)..<navigationHistory.count)
        }
        navigationHistory.append(page)
        navigationIndex = navigationHistory.count - 1
        selectedPage = page
    }

    // 只移动导航游标，不再追加历史；否则点后退本身会生成新记录，导致无法正确前进。
    private func navigateHistory(by offset: Int) {
        let newIndex = navigationIndex + offset
        guard navigationHistory.indices.contains(newIndex) else { return }
        navigationIndex = newIndex
        selectedPage = navigationHistory[newIndex]
    }

    // @ViewBuilder 是结果构建器：把闭包内的多个 View 和条件分支组合成一个静态类型的视图结果。
    @ViewBuilder
    private var pageContent: some View {
        switch selectedPage {
        case .general:
            generalSettings
        case .translation:
            translationSettings
        case .clipboard:
            clipboardSettings
        case .shortcuts:
            shortcutSettings
        case .privacy:
            privacySettings
        case .about:
            aboutSettings
        }
    }

    func toggleRow(_ title: String, binding: Binding<Bool>) -> some View {
        SettingsRow(title) {
            Toggle(title, isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(SettingsPalette.switchGreen)
        }
    }

    // UI 将“已启用”和“待系统批准”都显示为已选择；是否真正生效仍由状态说明区分。
    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: {
                launchAtLoginStatus == .enabled || launchAtLoginStatus == .requiresApproval
            },
            set: { shouldLaunchAtLogin in
                updateLaunchAtLogin(shouldLaunchAtLogin)
            }
        )
    }

    var launchAtLoginStatusDescription: String {
        switch launchAtLoginStatus {
        case .enabled:
            AppText.text("已加入 macOS 登录项，登录后会自动在菜单栏运行")
        case .requiresApproval:
            AppText.text("已注册，但需要在 macOS 登录项设置中允许")
        case .notFound:
            AppText.text("系统未找到当前应用，请将 iSnipster 移到“应用程序”后重试")
        case .notRegistered:
            AppText.text("登录后自动启动 iSnipster，并保持在菜单栏运行")
        // 系统 enum 可能在新 SDK/系统中扩展；@unknown default 为未知值提供行为，同时帮助编译器提示新增已知分支。
        @unknown default:
            AppText.text("无法读取 macOS 登录项状态")
        }
    }

    private func refreshLaunchAtLoginStatus() {
        // ServiceManagement 管理登录启动注册；读 status 是查系统状态，register/unregister 才改变它。
        launchAtLoginStatus = SMAppService.mainApp.status
        if launchAtLoginStatus == .enabled || launchAtLoginStatus == .notRegistered {
            launchAtLoginErrorMessage = nil
        }
    }

    // 开关触发的是系统注册/注销，不是只改 UserDefaults；异常后重新读状态，避免把已达成目标的结果误显示为失败。
    private func updateLaunchAtLogin(_ shouldLaunchAtLogin: Bool) {
        let service = SMAppService.mainApp
        launchAtLoginErrorMessage = nil

        do {
            if shouldLaunchAtLogin {
                if service.status == .requiresApproval {
                    launchAtLoginStatus = .requiresApproval
                    SMAppService.openSystemSettingsLoginItems()
                    return
                }
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            refreshLaunchAtLoginStatus()
        } catch {
            launchAtLoginStatus = service.status
            // 抛错后系统状态也可能已经变化；以实际 status 判断目标是否达到，比仅根据 catch 判定失败更准确。
            let reachedRequestedState = shouldLaunchAtLogin
                ? launchAtLoginStatus == .enabled
                : launchAtLoginStatus == .notRegistered
            if !reachedRequestedState {
                launchAtLoginErrorMessage = AppText.format("设置失败：%@", error.localizedDescription)
            }
        }
    }

}
