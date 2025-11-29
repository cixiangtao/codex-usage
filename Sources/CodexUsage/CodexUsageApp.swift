import AppKit
import SwiftUI

@main
struct CodexUsageApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var viewModel = DashboardViewModel()
    @StateObject private var updateViewModel = UpdateCheckViewModel()

    init() {
        AppIcon.installApplicationIcon()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(viewModel: viewModel, settings: settings, updateViewModel: updateViewModel)
                .frame(width: 360)
        } label: {
            StatusBarLabel(
                snapshot: viewModel.snapshot,
                health: UsageHealth.evaluate(
                    snapshot: viewModel.snapshot,
                    warning: settings.warningThresholdPercent,
                    critical: settings.criticalThresholdPercent
                ),
                showPrimary: settings.showPrimaryWindowInStatusBar,
                showSecondary: settings.showSecondaryWindowInStatusBar,
                showLabels: settings.showStatusBarWindowLabels
            )
            .task {
                viewModel.startAutoRefresh(settings: settings)
            }
            .onChange(of: settings.refreshIntervalSeconds) {
                viewModel.startAutoRefresh(settings: settings)
            }
        }
        .menuBarExtraStyle(.window)

    }
}

struct StatusBarLabel: View {
    var snapshot: CodexUsageSnapshot
    var health: UsageHealth
    var showPrimary: Bool
    var showSecondary: Bool
    var showLabels: Bool

    var body: some View {
        HStack(spacing: labelText.isEmpty ? 0 : 5) {
            Image(systemName: iconName)
            if !labelText.isEmpty {
                Text(labelText)
                    .monospacedDigit()
            }
        }
    }

    private var labelText: String {
        var parts: [String] = []

        if showPrimary {
            parts.append(windowText(.primary))
        }

        if showSecondary {
            parts.append(windowText(.secondary))
        }

        if parts.isEmpty {
            return ""
        }

        return parts.joined(separator: " · ")
    }

    private func windowText(_ kind: CodexRateWindowKind) -> String {
        let window = kind.window(in: snapshot)

        guard let window else {
            return showLabels ? "\(kind.defaultDisplayName) --%" : "--%"
        }

        let percent = "\(Int(window.remainingPercent.rounded()))%"
        return showLabels ? "\(window.displayName) \(percent)" : percent
    }

    private var iconName: String {
        switch health {
        case .unavailable:
            "bolt.trianglebadge.exclamationmark"
        case .normal:
            AppIcon.statusSymbolName
        case .warning:
            "bolt.badge.clock"
        case .critical:
            "exclamationmark.triangle"
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var settings: AppSettings
    @ObservedObject var updateViewModel: UpdateCheckViewModel

    private var health: UsageHealth {
        UsageHealth.evaluate(
            snapshot: viewModel.snapshot,
            warning: settings.warningThresholdPercent,
            critical: settings.criticalThresholdPercent
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if viewModel.snapshot.constrainedRemainingPercent == nil {
                EmptyStateView(snapshot: viewModel.snapshot)
            } else {
                LimitSummaryView(snapshot: viewModel.snapshot)
                TokenSummaryView(points: viewModel.trendPoints)
                UsageTrendChartView(
                    points: viewModel.trendPoints,
                    rangeDays: $settings.usageTrendRangeDays
                )
            }

            if let error = viewModel.lastError {
                ErrorBanner(message: error)
            }

            footer
        }
        .padding(14)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await updateViewModel.checkIfNeeded()
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(health.tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(accountTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(planText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(updateText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HealthBadge(health: health)

            Button {
                Task {
                    await viewModel.refresh(settings: settings)
                }
            } label: {
                if viewModel.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("刷新用量")
        }
    }

    private var accountTitle: String {
        UsageFormatters.accountIdentifier(viewModel.snapshot.accountIdentifier)
    }

    private var planText: String {
        "套餐 \(UsageFormatters.planName(viewModel.snapshot.planType))"
    }

    private var updateText: String {
        "更新于 \(UsageFormatters.relativeDateString(for: viewModel.snapshot.capturedAt, relativeTo: Date()))前"
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                SettingsWindowPresenter.shared.show(
                    settings: settings,
                    viewModel: viewModel,
                    updateViewModel: updateViewModel
                )
            } label: {
                Label("设置", systemImage: "slider.horizontal.3")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if updateViewModel.isUpdateAvailable {
                Button {
                    Task {
                        await updateViewModel.performPrimaryUpdateAction()
                    }
                } label: {
                    Label {
                        Text(updateViewModel.primaryUpdateActionTitle)
                    } icon: {
                        if updateViewModel.isInstalling {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.app")
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.orange)
                .disabled(updateViewModel.isChecking || updateViewModel.isInstalling)
                .help(updateViewModel.primaryUpdateActionHelp)
            }

            Spacer()

            Button(role: .destructive) {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.top, 2)
    }
}

@MainActor
final class SettingsWindowPresenter {
    static let shared = SettingsWindowPresenter()

    private static let contentSize = NSSize(width: 500, height: 620)

    private var window: NSWindow?

    private init() {}

    func show(settings: AppSettings, viewModel: DashboardViewModel, updateViewModel: UpdateCheckViewModel) {
        if let window {
            show(window, floatsAboveOtherApps: false)
            return
        }

        let hostingController = NSHostingController(
            rootView: SettingsView(settings: settings, viewModel: viewModel, updateViewModel: updateViewModel)
                .frame(width: Self.contentSize.width, height: Self.contentSize.height)
        )

        let nextWindow = NSWindow(contentViewController: hostingController)
        nextWindow.setContentSize(Self.contentSize)
        nextWindow.title = "设置"
        nextWindow.styleMask = [.titled, .closable, .miniaturizable]
        nextWindow.isReleasedWhenClosed = false
        nextWindow.collectionBehavior = [.moveToActiveSpace]
        nextWindow.center()

        window = nextWindow
        show(nextWindow, floatsAboveOtherApps: true)
    }

    private func show(_ window: NSWindow, floatsAboveOtherApps: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        window.level = floatsAboveOtherApps ? .floating : .normal
        window.makeKeyAndOrderFront(nil)

        guard floatsAboveOtherApps else { return }

        window.orderFrontRegardless()
        DispatchQueue.main.async { [weak window] in
            window?.level = .normal
        }
    }
}

struct LimitSummaryView: View {
    var snapshot: CodexUsageSnapshot

    var body: some View {
        VStack(spacing: 10) {
            if let primary = snapshot.primary {
                RateWindowRow(window: primary)
            }

            if let secondary = snapshot.secondary {
                RateWindowRow(window: secondary)
            }

            ResetCardSummaryView(info: snapshot.resetCards)
        }
    }
}

struct RateWindowRow: View {
    var window: RateWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(window.displayName)
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text(UsageFormatters.percent(window.remainingPercent))
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(windowTint)
                }

                Text(windowDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: progressValue)
                .tint(windowTint)
                .controlSize(.small)
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        )
    }

    private var windowDescription: String {
        let windowText = window.windowMinutes.map { windowDurationText(minutes: $0) } ?? "窗口未知"
        return "\(windowText) · \(UsageFormatters.resetText(window.resetsAt))"
    }

    private func windowDurationText(minutes: Int) -> String {
        if minutes >= 1_440, minutes % 1_440 == 0 {
            return "\(minutes / 1_440) 天窗口"
        }

        if minutes >= 60, minutes % 60 == 0 {
            return "\(minutes / 60) 小时窗口"
        }

        return "\(minutes) 分钟窗口"
    }

    private var progressValue: Double {
        max(0, min(1, window.remainingPercent / 100))
    }

    private var windowTint: Color {
        switch window.remainingPercent {
        case ...10:
            .red
        case ...25:
            .orange
        default:
            .green
        }
    }
}

struct ResetCardSummaryView: View {
    var info: ResetCardInfo?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.counterclockwise.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text("重置卡")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text(countText)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(tint)
                }

                Text(expirationText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        )
    }

    private var countText: String {
        guard let info else { return "未知" }

        if info.unlimited {
            return "不限次数"
        }

        if let balance = info.balance {
            return "剩余 \(balance) 次"
        }

        if info.hasCards == true {
            return "可用"
        }

        if info.hasCards == false {
            return "暂无可用"
        }

        return "未知"
    }

    private var expirationText: String {
        guard let expiresAt = info?.expiresAt else {
            return "最近过期时间未提供"
        }

        let now = Date()
        if expiresAt <= now {
            return "最近一张已过期 · \(UsageFormatters.fullDateTime(expiresAt))"
        }

        return "最近过期 \(UsageFormatters.relativeDateString(for: expiresAt, relativeTo: now))后 · \(UsageFormatters.fullDateTime(expiresAt))"
    }

    private var tint: Color {
        guard let info else { return .secondary }

        if info.unlimited || (info.balance.map { $0 > 0 } ?? (info.hasCards == true)) {
            return .accentColor
        }

        return .secondary
    }
}

struct TokenSummaryView: View {
    var points: [UsageTrendPoint]

    private var recentPoints: [UsageTrendPoint] {
        points.filter { $0.totalTokens > 0 }
    }

    var body: some View {
        if !points.isEmpty {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    tokenCell(todayLabel, todayTotal, icon: "calendar")
                    tokenCell("近 7 天估算", total(forLastDays: 7), icon: "chart.bar")
                }

                GridRow {
                    tokenCell("近 30 天估算", total(forLastDays: 30), icon: "sum")
                    tokenCell("日均估算", dailyAverage, icon: "divide")
                }
            }
        }
    }

    private var todayLabel: String {
        guard let latest = points.last else { return "今日估算" }
        return Calendar.current.isDateInToday(latest.capturedAt) ? "今日估算" : "最近估算"
    }

    private var todayTotal: Int {
        points.last?.totalTokens ?? 0
    }

    private var dailyAverage: Int {
        guard !recentPoints.isEmpty else { return 0 }
        let total = recentPoints.reduce(0) { $0 + $1.totalTokens }
        return Int((Double(total) / Double(recentPoints.count)).rounded())
    }

    private func total(forLastDays days: Int) -> Int {
        points.suffix(days).reduce(0) { $0 + $1.totalTokens }
    }

    private func tokenCell(_ label: String, _ value: Int, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Text(UsageFormatters.compactTokens(value))
                    .font(.callout.monospacedDigit().weight(.semibold))
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct UsageTrendChartView: View {
    var points: [UsageTrendPoint]
    @Binding var rangeDays: Int
    @State private var hoveredPointID: String?

    private let barSpacing: Double = 3
    private let barWidth: Double = 6
    private let rangeOptions = [7, 14, 30]

    private var displayedPoints: [UsageTrendPoint] {
        Array(points.suffix(validRangeDays))
    }

    var body: some View {
        if !displayedPoints.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Label("每日用量估算", systemImage: "chart.bar.fill")
                        .font(.subheadline.weight(.semibold))

                    Spacer()

                    Text(readoutText)
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Picker("展示范围", selection: $rangeDays) {
                    ForEach(rangeOptions, id: \.self) { days in
                        Text("\(days)天").tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .help("切换每日用量图表的展示范围")

                GeometryReader { proxy in
                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(displayedPoints) { point in
                            Capsule(style: .continuous)
                                .fill(barColor(for: point))
                                .frame(width: barWidth, height: barHeight(for: point, in: proxy.size.height))
                                .contentShape(Rectangle())
                                .onHover { isHovering in
                                    hoveredPointID = isHovering ? point.id : nil
                                }
                                .accessibilityLabel(tooltipText(for: point))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 58)
                .accessibilityLabel("每日 token 用量估算变化")

                HStack {
                    Text(dayText(for: displayedPoints.first?.capturedAt))
                    Spacer()
                    Text(dayText(for: displayedPoints.last?.capturedAt))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.separator.opacity(0.35), lineWidth: 1)
            )
        }
    }

    private var readoutText: String {
        guard let hoveredPoint else { return summaryText }
        return "\(dayText(for: hoveredPoint.capturedAt)) \(UsageFormatters.compactTokens(hoveredPoint.totalTokens))"
    }

    private var hoveredPoint: UsageTrendPoint? {
        guard let hoveredPointID else { return nil }
        return displayedPoints.first { $0.id == hoveredPointID }
    }

    private var summaryText: String {
        guard let latest = displayedPoints.last else { return "--" }
        let prefix = Calendar.current.isDateInToday(latest.capturedAt) ? "今日" : "最近"
        return "\(prefix) \(UsageFormatters.compactTokens(latest.totalTokens))"
    }

    private var validRangeDays: Int {
        rangeOptions.contains(rangeDays) ? rangeDays : 30
    }

    private var maxTokens: Int {
        max(displayedPoints.map(\.totalTokens).max() ?? 0, 1)
    }

    private func barHeight(for point: UsageTrendPoint, in availableHeight: Double) -> Double {
        let ratio = Double(point.totalTokens) / Double(maxTokens)
        return max(4, availableHeight * ratio)
    }

    private func barColor(for point: UsageTrendPoint) -> Color {
        guard point.totalTokens > 0 else {
            return Color(nsColor: .quaternaryLabelColor).opacity(0.35)
        }

        guard let latest = displayedPoints.last else {
            return .accentColor.opacity(0.55)
        }

        if point.id == hoveredPointID {
            return .accentColor
        }

        return point.id == latest.id ? .accentColor.opacity(0.8) : .accentColor.opacity(0.45)
    }

    private func dayText(for date: Date?) -> String {
        guard let date else { return "--" }
        return UsageFormatters.shortDay(date)
    }

    private func tooltipText(for point: UsageTrendPoint) -> String {
        "\(UsageFormatters.fullDate(point.capturedAt)) · \(UsageFormatters.compactTokens(point.totalTokens)) tokens"
    }
}

struct EmptyStateView: View {
    var snapshot: CodexUsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text("还没有用量快照")
                    .font(.subheadline.weight(.semibold))
            }

            Text("先运行一次 Codex，然后刷新。应用会优先读取接口数据，必要时回退本地会话日志。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(snapshot.source)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        )
    }
}

struct HealthBadge: View {
    var health: UsageHealth

    var body: some View {
        Label(health.title, systemImage: health.iconName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(health.tint)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(health.tint.opacity(0.12), in: Capsule())
    }
}

struct ErrorBanner: View {
    var message: String

    var body: some View {
        Label {
            Text(message)
                .font(.caption)
                .lineLimit(3)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(.red)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private extension UsageHealth {
    var title: String {
        switch self {
        case .unavailable:
            "等待"
        case .normal:
            "充足"
        case .warning:
            "注意"
        case .critical:
            "紧张"
        }
    }

    var iconName: String {
        switch self {
        case .unavailable:
            "clock"
        case .normal:
            "checkmark.circle.fill"
        case .warning:
            "clock.badge.exclamationmark"
        case .critical:
            "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .unavailable:
            .secondary
        case .normal:
            .green
        case .warning:
            .orange
        case .critical:
            .red
        }
    }
}

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var viewModel: DashboardViewModel
    @ObservedObject var updateViewModel: UpdateCheckViewModel
    @StateObject private var intelligenceCheckViewModel = CodexIntelligenceCheckViewModel()
    #if DEBUG
    @State private var debugNotificationAlertMessage = ""
    @State private var debugNotificationAlertTitle = ""
    @State private var isDebugNotificationAlertPresented = false
    @State private var sendingDebugNotificationTarget: CodexRateWindowKind?
    #endif
    @State private var isResetConfirmationPresented = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                settingsHeader

                SettingsSection(
                    icon: "arrow.clockwise",
                    title: "刷新",
                    subtitle: "控制状态栏和面板读取本地快照的频率。"
                ) {
                    RefreshIntervalControl(seconds: $settings.refreshIntervalSeconds)
                }

                SettingsSection(
                    icon: "menubar.rectangle",
                    title: "状态栏",
                    subtitle: "选择状态栏里常驻展示的额度窗口和格式。"
                ) {
                    VStack(spacing: 10) {
                        ToggleRow(
                            title: CodexRateWindowKind.primary.settingsTitle,
                            subtitle: "例如 \(CodexRateWindowKind.primary.exampleText)",
                            isOn: primaryStatusBinding
                        )

                        ToggleRow(
                            title: CodexRateWindowKind.secondary.settingsTitle,
                            subtitle: "例如 \(CodexRateWindowKind.secondary.exampleText)",
                            isOn: secondaryStatusBinding
                        )

                        ToggleRow(
                            title: "显示额度名称",
                            subtitle: "开启为 \(CodexRateWindowKind.primary.exampleText)，关闭为 86%",
                            isOn: $settings.showStatusBarWindowLabels
                        )
                    }
                }

                SettingsSection(
                    icon: "bell.badge",
                    title: "通知",
                    subtitle: "在剩余额度进入压力区间时提醒。"
                ) {
                    VStack(spacing: 12) {
                        ToggleRow(
                            title: "启用通知",
                            subtitle: "首次开启时 macOS 会请求通知权限。",
                            isOn: $settings.notificationsEnabled
                        )

                        #if DEBUG
                        NotificationDebugRows(
                            isEnabled: settings.notificationsEnabled,
                            primaryWindow: viewModel.snapshot.primary,
                            secondaryWindow: viewModel.snapshot.secondary,
                            sendingTarget: sendingDebugNotificationTarget,
                            action: sendDebugNotification
                        )
                        #endif

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

                SettingsSection(
                    icon: "power.circle",
                    title: "系统",
                    subtitle: "管理 CodexUsage 是否随 macOS 登录自动启动。"
                ) {
                    LoginItemRows()
                }

                SettingsSection(
                    icon: "brain.head.profile",
                    title: "降智检测",
                    subtitle: "手动运行轻量样本，给出当前模型状态结论。"
                ) {
                    CodexIntelligenceCheckRows(
                        viewModel: intelligenceCheckViewModel,
                        codexHomePath: settings.codexHomePath
                    )
                }

                SettingsSection(
                    icon: "arrow.down.circle",
                    title: "更新",
                    subtitle: "从 GitLab Release 检查新版本。"
                ) {
                    UpdateCheckRows(viewModel: updateViewModel)
                }

                SettingsSection(
                    icon: "arrow.counterclockwise",
                    title: "重置设置",
                    subtitle: "恢复默认偏好。"
                ) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("恢复默认设置")
                                .font(.callout.weight(.medium))

                            Text("刷新、状态栏和通知偏好会恢复到初始状态")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            isResetConfirmationPresented = true
                        } label: {
                            Label("重置", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            await updateViewModel.checkIfNeeded()
        }
        .alert("重置偏好设置？", isPresented: $isResetConfirmationPresented) {
            Button("取消", role: .cancel) {}
            Button("重置", role: .destructive) {
                withAnimation(.easeInOut(duration: 0.18)) {
                    settings.reset()
                }
            }
        } message: {
            Text("这会恢复刷新间隔、状态栏展示、通知阈值、图表范围和 Codex 路径设置。")
        }
        #if DEBUG
        .alert(debugNotificationAlertTitle, isPresented: $isDebugNotificationAlertPresented) {
            Button("好", role: .cancel) {}
        } message: {
            Text(debugNotificationAlertMessage)
        }
        #endif
    }

    private var settingsHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 18, weight: .semibold))

                Text("Codex 用量监控偏好")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }

    private var primaryStatusBinding: Binding<Bool> {
        Binding {
            settings.showPrimaryWindowInStatusBar
        } set: { isOn in
            settings.showPrimaryWindowInStatusBar = isOn
        }
    }

    private var secondaryStatusBinding: Binding<Bool> {
        Binding {
            settings.showSecondaryWindowInStatusBar
        } set: { isOn in
            settings.showSecondaryWindowInStatusBar = isOn
        }
    }

    #if DEBUG
    private func sendDebugNotification(for target: CodexRateWindowKind) {
        guard sendingDebugNotificationTarget == nil,
              let window = target.window(in: viewModel.snapshot) else {
            return
        }

        sendingDebugNotificationTarget = target
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
                    debugNotificationAlertTitle = "测试通知已发送"
                    debugNotificationAlertMessage = "已按 \(testWindow.displayName) 模拟真实提醒。"
                case .developmentPreview:
                    debugNotificationAlertTitle = "开发预览通知已发送"
                    debugNotificationAlertMessage = "当前是 swift run 开发运行，已按 \(testWindow.displayName) 预览真实提醒效果。"
                }
            } catch {
                debugNotificationAlertTitle = "测试通知失败"
                debugNotificationAlertMessage = error.localizedDescription
            }

            sendingDebugNotificationTarget = nil
            isDebugNotificationAlertPresented = true
        }
    }

    private func simulatedNotificationWindow(from window: RateWindow) -> RateWindow {
        let health = notificationHealth(for: window)
        guard health == .normal else { return window }

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

struct LoginItemRows: View {
    @StateObject private var controller = LoginItemController()

    var body: some View {
        VStack(spacing: 10) {
            ToggleRow(
                title: "开机自启",
                subtitle: controller.statusText,
                isOn: Binding {
                    controller.isEnabled
                } set: { isOn in
                    controller.setEnabled(isOn)
                },
                isDisabled: controller.isBusy || !controller.canManageLoginItem
            )

            if let errorMessage = controller.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
            }

            if controller.shouldOfferSystemSettings {
                HStack {
                    Spacer()

                    Button {
                        controller.openLoginItemsSettings()
                    } label: {
                        Label("打开登录项", systemImage: "gear")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .task {
            controller.refresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refresh()
        }
    }
}

@MainActor
final class UpdateCheckViewModel: ObservableObject {
    @Published private(set) var result: UpdateCheckResult?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isChecking = false
    @Published private(set) var isInstalling = false
    @Published private(set) var installMessage: String?

    let currentVersion = UpdateChecker.currentVersion

    private let checker = UpdateChecker()
    private let installer = UpdateInstaller()

    var isUpdateAvailable: Bool {
        result?.isUpdateAvailable == true
    }

    var canInstallAvailableUpdate: Bool {
        guard let result, result.isUpdateAvailable else { return false }
        return result.downloadURL != nil && UpdateInstaller.canInstallCurrentApplication
    }

    var primaryUpdateActionTitle: String {
        if isInstalling {
            return "安装中"
        }

        return canInstallAvailableUpdate ? "下载并更新" : "打开发布页"
    }

    var primaryUpdateActionHelp: String {
        canInstallAvailableUpdate ? "下载并更新到新版本" : "当前环境无法自动安装，打开发布页"
    }

    func checkIfNeeded() async {
        guard result == nil, errorMessage == nil else { return }
        await check()
    }

    func check() async {
        guard !isChecking, !isInstalling else { return }

        isChecking = true
        errorMessage = nil
        installMessage = nil

        do {
            result = try await checker.checkForUpdates()
        } catch {
            errorMessage = error.localizedDescription
        }

        isChecking = false
    }

    func openDownload() {
        guard let result else { return }
        NSWorkspace.shared.open(result.releasePageURL)
    }

    func performPrimaryUpdateAction() async {
        guard let result, result.isUpdateAvailable else { return }

        if canInstallAvailableUpdate {
            await installUpdateAndRelaunch()
        } else {
            openDownload()
        }
    }

    func installUpdateAndRelaunch() async {
        guard !isChecking, !isInstalling else { return }
        guard let result, result.isUpdateAvailable else { return }
        guard let downloadURL = result.downloadURL else {
            errorMessage = UpdateInstallError.missingDownloadURL.localizedDescription
            return
        }

        isInstalling = true
        errorMessage = nil
        installMessage = "正在下载更新"

        do {
            let plan = try await installer.prepareInstall(from: downloadURL)
            installMessage = "正在重启应用"
            try installer.installAndRelaunch(plan)
            NSApplication.shared.terminate(nil)
        } catch {
            installMessage = nil
            errorMessage = error.localizedDescription
            isInstalling = false
        }
    }
}

struct UpdateCheckRows: View {
    @ObservedObject var viewModel: UpdateCheckViewModel

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(statusTitle)
                        .font(.callout.weight(.medium))

                    Text(statusSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                updateBadge
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            HStack(spacing: 8) {
                Button {
                    Task {
                        await viewModel.check()
                    }
                } label: {
                    Label {
                        Text(viewModel.isChecking ? "检查中" : "检查更新")
                    } icon: {
                        if viewModel.isChecking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(viewModel.isChecking || viewModel.isInstalling)

                if let result = viewModel.result,
                   result.isUpdateAvailable,
                   result.downloadURL != nil,
                   UpdateInstaller.canInstallCurrentApplication {
                    Button {
                        Task {
                            await viewModel.installUpdateAndRelaunch()
                        }
                    } label: {
                        Label {
                            Text(viewModel.isInstalling ? "安装中" : "下载并更新")
                        } icon: {
                            if viewModel.isInstalling {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.down.app")
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(.orange)
                    .disabled(viewModel.isChecking || viewModel.isInstalling)
                }
                /*
                else if viewModel.result != nil {
                    Button {
                        viewModel.openDownload()
                    } label: {
                        Label(downloadButtonTitle, systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(viewModel.isChecking || viewModel.isInstalling)
                }
                */

                Spacer()
            }
        }
    }

    @ViewBuilder
    private var updateBadge: some View {
        if viewModel.isChecking || viewModel.isInstalling {
            ProgressView()
                .controlSize(.small)
        } else if let result = viewModel.result {
            Text(result.isUpdateAvailable ? "可更新" : "最新")
                .font(.caption.weight(.semibold))
                .foregroundStyle(result.isUpdateAvailable ? .orange : .green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background((result.isUpdateAvailable ? Color.orange : Color.green).opacity(0.12), in: Capsule())
        } else if viewModel.errorMessage != nil {
            Text("失败")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.red.opacity(0.12), in: Capsule())
        } else {
            Text("未检查")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.12), in: Capsule())
        }
    }

    private var statusTitle: String {
        if viewModel.isInstalling {
            return "正在安装更新"
        }

        if viewModel.isChecking {
            return "正在检查更新"
        }

        if let result = viewModel.result {
            return result.isUpdateAvailable ? "发现新版本 \(result.latestVersion)" : "已是最新版本"
        }

        if viewModel.errorMessage != nil {
            return "更新检测失败"
        }

        return "当前版本 \(viewModel.currentVersion)"
    }

    private var statusSubtitle: String {
        if let installMessage = viewModel.installMessage {
            return installMessage
        }

        if let errorMessage = viewModel.errorMessage {
            return errorMessage
        }

        guard let result = viewModel.result else {
            return "打开设置时会自动检查一次，也可以手动重试。"
        }

        if result.isUpdateAvailable {
            if result.downloadURL == nil {
                return "当前 \(result.currentVersion)，最新 \(result.releaseName)，但没有找到 zip 安装包。"
            }

            if !UpdateInstaller.canInstallCurrentApplication {
                return "当前 \(result.currentVersion)，最新 \(result.releaseName)。自动安装需要 release 版 .app。"
            }

            return "当前 \(result.currentVersion)，最新 \(result.releaseName)，可自动下载并重启。"
        }

        return "当前 \(result.currentVersion)，GitLab 最新 \(result.latestVersion)。"
    }

    private var downloadButtonTitle: String {
        "打开发布页"
    }
}

struct SettingsSection<Content: View>: View {
    var icon: String
    var title: String
    var subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))

                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            content
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.separator.opacity(0.35), lineWidth: 1)
        )
    }
}

struct ToggleRow: View {
    var title: String
    var subtitle: String
    @Binding var isOn: Bool
    var isDisabled = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.callout.weight(.medium))

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            SwitchControl(isOn: $isOn)
                .disabled(isDisabled)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isDisabled ? 0.62 : 1)
    }
}

#if DEBUG
struct NotificationDebugRows: View {
    var isEnabled: Bool
    var primaryWindow: RateWindow?
    var secondaryWindow: RateWindow?
    var sendingTarget: CodexRateWindowKind?
    var action: (CodexRateWindowKind) -> Void

    var body: some View {
        VStack(spacing: 8) {
            debugRow(target: .primary, window: primaryWindow)
            debugRow(target: .secondary, window: secondaryWindow)
        }
    }

    private func debugRow(target: CodexRateWindowKind, window: RateWindow?) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("测试 \(window?.displayName ?? target.defaultDisplayName) 通知")
                    .font(.callout.weight(.medium))

                Text(subtitle(for: window))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            debugButton(target: target, window: window)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func debugButton(target: CodexRateWindowKind, window: RateWindow?) -> some View {
        let isSending = sendingTarget == target
        let isDisabled = !isEnabled || window == nil || sendingTarget != nil

        return Button {
            action(target)
        } label: {
            Label {
                Text(isSending ? "发送中" : "发送")
            } icon: {
                if isSending {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(isDisabled)
        .help(helpText(for: window))
    }

    private func subtitle(for window: RateWindow?) -> String {
        guard let window else {
            return isEnabled ? "等待本地快照后可测试" : "开启通知后可发送测试提醒"
        }

        return "\(window.displayName) · 当前剩余 \(UsageFormatters.percent(window.remainingPercent))"
    }

    private func helpText(for window: RateWindow?) -> String {
        guard let window else { return "没有可用于测试的额度快照" }
        return "按 \(window.displayName) 模拟发送真实通知"
    }
}
#endif

struct SwitchControl: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isOn ? Color.green : Color(nsColor: .quaternaryLabelColor).opacity(0.26))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(trackBorder, lineWidth: 1)
                    )

                Circle()
                    .fill(.white)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.16), radius: 2, x: 0, y: 1)
                    .padding(3)
            }
            .frame(width: 42, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isOn ? "开启" : "关闭")
        .accessibilityValue(isOn ? "开启" : "关闭")
    }

    private var trackBorder: Color {
        isOn ? Color.green.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.45)
    }
}

struct RefreshIntervalControl: View {
    @Binding var seconds: Double

    private let presets: [Double] = [15, 30, 60, 120, 300]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button(presetTitle(preset)) {
                        seconds = preset
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(Int(seconds) == Int(preset) ? .accentColor : .secondary)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("自定义间隔")
                        .font(.callout.weight(.medium))

                    Text("最短 15 秒，最长 15 分钟")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Stepper(
                    "\(Int(seconds)) 秒",
                    value: $seconds,
                    in: 15...900,
                    step: 15
                )
                .monospacedDigit()
                .frame(width: 120, alignment: .trailing)
            }
            .padding(10)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func presetTitle(_ value: Double) -> String {
        switch Int(value) {
        case 60:
            "1 分钟"
        case 120:
            "2 分钟"
        case 300:
            "5 分钟"
        default:
            "\(Int(value)) 秒"
        }
    }
}

struct SliderRow: View {
    var title: String
    var detail: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.medium))

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(UsageFormatters.percent(value))
                    .font(.callout.monospacedDigit().weight(.semibold))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(tint.opacity(0.12), in: Capsule())
            }

            Slider(value: $value, in: range, step: 1)
                .tint(tint)
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
