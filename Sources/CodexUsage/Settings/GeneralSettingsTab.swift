import SwiftUI

struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsTabPage(
            title: "常规",
            subtitle: "配置状态栏展示、刷新节奏与系统启动行为。"
        ) {
            SettingsSection(
                icon: "menubar.rectangle",
                title: "状态栏",
                subtitle: "选择常驻展示的额度窗口、格式和内置图标。"
            ) {
                VStack(spacing: 10) {
                    StatusBarIconPicker(selection: $settings.statusBarIconStyle)

                    ToggleRow(
                        title: CodexRateWindowKind.primary.settingsTitle,
                        subtitle: "例如 \(CodexRateWindowKind.primary.exampleText)",
                        isOn: $settings.showPrimaryWindowInStatusBar
                    )

                    ToggleRow(
                        title: CodexRateWindowKind.secondary.settingsTitle,
                        subtitle: "例如 \(CodexRateWindowKind.secondary.exampleText)",
                        isOn: $settings.showSecondaryWindowInStatusBar
                    )

                    ToggleRow(
                        title: "显示额度名称",
                        subtitle: "开启为 \(CodexRateWindowKind.primary.exampleText)，关闭为 86%",
                        isOn: $settings.showStatusBarWindowLabels
                    )
                }
            }

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
