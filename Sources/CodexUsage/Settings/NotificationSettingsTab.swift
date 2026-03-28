import SwiftUI

struct NotificationSettingsTab: View {
    @ObservedObject var settings: AppSettings
    #if DEBUG
    @ObservedObject var viewModel: DashboardViewModel
    @State private var alertMessage = ""
    @State private var alertTitle = ""
    @State private var isAlertPresented = false
    @State private var sendingTarget: CodexRateWindowKind?
    #endif

    #if DEBUG
    init(settings: AppSettings, viewModel: DashboardViewModel) {
        self.settings = settings
        self.viewModel = viewModel
    }
    #else
    init(settings: AppSettings) {
        self.settings = settings
    }
    #endif

    var body: some View {
        SettingsTabPage(
            title: "通知",
            subtitle: "决定何时提醒，以及什么额度状态需要你的注意。"
        ) {
            SettingsSection(
                icon: "bell.badge",
                title: "额度提醒",
                subtitle: "在剩余额度进入压力区间时发送系统通知。"
            ) {
                VStack(spacing: 12) {
                    ToggleRow(
                        title: "启用通知",
                        subtitle: "首次开启时 macOS 会请求通知权限。",
                        isOn: $settings.notificationsEnabled
                    )

                    SliderRow(
                        title: "提醒阈值",
                        detail: "低于该比例时标记为注意",
                        value: $settings.warningThresholdPercent,
                        range: 1...80,
                        tint: .orange
                    )

                    SliderRow(
                        title: "严重阈值",
                        detail: "低于该比例时标记为紧张",
                        value: $settings.criticalThresholdPercent,
                        range: 1...50,
                        tint: .red
                    )
                }
            }

            #if DEBUG
            SettingsSection(
                icon: "paperplane",
                title: "通知测试",
                subtitle: "开发模式下使用当前额度快照预览真实提醒。"
            ) {
                NotificationDebugRows(
                    isEnabled: settings.notificationsEnabled,
                    primaryWindow: CodexRateWindowKind.primary.window(in: viewModel.snapshot),
                    secondaryWindow: CodexRateWindowKind.secondary.window(in: viewModel.snapshot),
                    sendingTarget: sendingTarget,
                    action: sendDebugNotification
                )
            }
            #endif
        }
        #if DEBUG
        .alert(alertTitle, isPresented: $isAlertPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        #endif
    }

    #if DEBUG
    private func sendDebugNotification(for target: CodexRateWindowKind) {
        guard sendingTarget == nil,
              let window = target.window(in: viewModel.snapshot) else {
            return
        }

        sendingTarget = target
        Task {
            do {
                let testWindow = simulatedNotificationWindow(from: window)
                let health = notificationHealth(for: testWindow)
                let delivery = try await NotificationManager().sendDebugNotification(
                    window: testWindow,
                    health: health
                )
                switch delivery {
                case .appBundle:
                    alertTitle = "测试通知已发送"
                    alertMessage = "已按 \(testWindow.displayName) 模拟真实提醒。"
                case .developmentPreview:
                    alertTitle = "开发预览通知已发送"
                    alertMessage = "当前是 swift run 开发运行，已按 \(testWindow.displayName) 预览真实提醒效果。"
                }
            } catch {
                alertTitle = "测试通知失败"
                alertMessage = error.localizedDescription
            }

            sendingTarget = nil
            isAlertPresented = true
        }
    }

    private func simulatedNotificationWindow(from window: RateWindow) -> RateWindow {
        guard notificationHealth(for: window) == .normal else { return window }

        let simulatedRemaining = max(0, min(100, settings.warningThresholdPercent))
        return RateWindow(
            name: window.displayName,
            usedPercent: 100 - simulatedRemaining,
            windowMinutes: window.windowMinutes,
            resetsAt: window.resetsAt
        )
    }

    private func notificationHealth(for window: RateWindow) -> UsageHealth {
        if window.remainingPercent <= settings.criticalThresholdPercent {
            return .critical
        }

        if window.remainingPercent <= settings.warningThresholdPercent {
            return .warning
        }

        return .normal
    }
    #endif
}
