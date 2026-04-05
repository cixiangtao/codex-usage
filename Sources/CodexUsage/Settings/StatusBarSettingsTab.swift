import SwiftUI

struct StatusBarSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsTabPage(
            title: "状态栏",
            subtitle: "控制菜单栏中常驻显示的额度内容和文字格式。"
        ) {
            SettingsSection(
                icon: "menubar.rectangle",
                title: "额度窗口",
                subtitle: "按需组合两个额度周期，至少保留图标时也可以关闭全部文字。"
            ) {
                VStack(spacing: 10) {
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
                }
            }

            SettingsSection(
                icon: "textformat",
                title: "文字格式",
                subtitle: "决定额度数值前是否显示周期名称。"
            ) {
                ToggleRow(
                    title: "显示额度名称",
                    subtitle: "开启为 \(CodexRateWindowKind.primary.exampleText)，关闭为 86%",
                    isOn: $settings.showStatusBarWindowLabels
                )
            }
        }
    }
}
