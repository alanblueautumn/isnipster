// 阅读路线
// 直接读取安装包 Info.plist 中的版本和发版日期。
// 官方参考（Bundle 应用元数据）：https://developer.apple.com/documentation/foundation/bundle

import Foundation
import MacPlatform
import iSnipsterCore
import SwiftUI

/// “关于”页展示发布信息和当前运行环境。
extension SettingsView {
    var aboutSettings: some View {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let releaseDate = (Bundle.main.object(forInfoDictionaryKey: "AppReleaseDate") as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // HStack 横排、VStack 竖排、ZStack 叠放；闭包是子视图声明，布局随输入状态重新计算。
        return VStack(spacing: 20) {
            VStack(spacing: 12) {
                Image(systemName: "viewfinder")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    // frame 给当前内容包一层布局约束，不是直接设置 DOM 宽高；修饰器前后顺序会影响背景与可点击范围。
                    .frame(width: 88, height: 88)
                    // background 画在当前内容后面；它位于哪一个 frame/padding 之后，会决定背景所覆盖的尺寸。
                    .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 20))
                Text("iSnipster")
                    .font(.system(size: 22, weight: .bold))
                Text(AppText.format("版本 %@", version.isEmpty ? "—" : version))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(AppText.format("发版日期 %@", releaseDate.isEmpty ? AppText.text("待发布") : releaseDate))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                Text(AppText.text("快速截图、管理剪贴板与翻译文本的 macOS 菜单栏工具。"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            // padding 在当前内容外增加布局留白；先 padding 再 background，背景会覆盖这部分留白。
            .padding(.vertical, 26)

            SettingsGroup(title: AppText.text("应用信息")) {
                SettingsRows {
                    SettingsRow(AppText.text("数据存储")) {
                        Text(AppText.text("仅存储在本机"))
                            .foregroundStyle(.secondary)
                    }
                    SettingsRow(AppText.text("运行环境")) {
                        Text("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Text("© 2026 iSnipster")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
    }
}
