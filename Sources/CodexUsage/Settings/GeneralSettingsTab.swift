import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsTabPage(
            title: "常规",
            subtitle: "配置刷新节奏与系统启动行为。"
        ) {
            SettingsSection(
                icon: "arrow.clockwise",
                title: "刷新",
                subtitle: "控制状态栏额度与通知的刷新频率。"
            ) {
                RefreshIntervalControl(seconds: $settings.refreshIntervalSeconds)
            }

            SettingsSection(
                icon: "power.circle",
                title: "系统",
                subtitle: "管理 CodexUsage 是否随 macOS 登录自动启动。"
            ) {
                LoginItemRows()
            }
        }
    }
}
