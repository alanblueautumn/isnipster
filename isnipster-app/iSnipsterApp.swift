// 阅读路线
// 学习起点：@main → App 协议 → Settings Scene → AppDelegate。Scene 管窗口场景，View 管场景内的界面。
// SwiftUI 的 body 类似 Vue 模板的声明入口，会随状态重算；不要把网络或截图操作直接写进 body。
// 官方参考（App 与 Scene）：https://developer.apple.com/documentation/swiftui/app

import MacPlatform
import SwiftUI

/// 应用入口：macOS 根据 `@main` 创建 `App`，SwiftUI 接管事件循环；`body` 声明应用拥有的 Scene，
/// 并非按顺序创建控件。阅读链路可从这里进入 `AppDelegate → CompositionRoot → AppModel → Feature → MacPlatform`。
/// SwiftUI、Observation 与并发模型也适用于 iOS；本项目的 AppKit/ScreenCaptureKit 适配则是 macOS 特有部分。
@main
struct iSnipsterApp: App {
    /// SwiftUI 负责 App 的 Scene，AppKit 负责快捷键、剪贴板等传统生命周期事件。
    /// `@NSApplicationDelegateAdaptor` 是二者的桥梁，类似把一个框架托管的 Bean
    /// 注入应用入口；它还会保证 AppDelegate 在应用存活期间不会被释放。
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // init 是构造器，调用类型名即构造实例，不写 new；这里为下一次启动准备系统语言偏好。
    init() {
        AppUILanguage.prepareForNextLaunch(AppUILanguage.selected)
    }

    // var 声明属性，冒号后是类型；这个属性只有 getter，每次读取计算 Scene 描述而非存储第二份界面。
    var body: some Scene {
        // Settings 是独立 Scene；系统负责处理标准的“设置…”菜单和窗口复用。
        Settings {
            SettingsView(model: appDelegate.root.appModel)
        }
    }
}
