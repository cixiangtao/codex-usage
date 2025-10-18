import Foundation

@MainActor
final class AppSettings: ObservableObject {
    @Published var codexHomePath: String {
        didSet { defaults.set(codexHomePath, forKey: Keys.codexHomePath) }
    }

    @Published var refreshIntervalSeconds: Double {
        didSet { defaults.set(refreshIntervalSeconds, forKey: Keys.refreshIntervalSeconds) }
    }

    @Published var warningThresholdPercent: Double {
        didSet { defaults.set(warningThresholdPercent, forKey: Keys.warningThresholdPercent) }
    }

    @Published var criticalThresholdPercent: Double {
        didSet { defaults.set(criticalThresholdPercent, forKey: Keys.criticalThresholdPercent) }
    }

    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }

    @Published var showPrimaryWindowInStatusBar: Bool {
        didSet { defaults.set(showPrimaryWindowInStatusBar, forKey: Keys.showPrimaryWindowInStatusBar) }
    }

    @Published var showSecondaryWindowInStatusBar: Bool {
        didSet { defaults.set(showSecondaryWindowInStatusBar, forKey: Keys.showSecondaryWindowInStatusBar) }
    }

    @Published var showStatusBarWindowLabels: Bool {
        didSet { defaults.set(showStatusBarWindowLabels, forKey: Keys.showStatusBarWindowLabels) }
    }

    @Published var usageTrendRangeDays: Int {
        didSet { defaults.set(usageTrendRangeDays, forKey: Keys.usageTrendRangeDays) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let defaultValues = DefaultValues.current

        codexHomePath = defaults.string(forKey: Keys.codexHomePath) ?? defaultValues.codexHomePath
        refreshIntervalSeconds = defaults.object(forKey: Keys.refreshIntervalSeconds) as? Double ?? defaultValues.refreshIntervalSeconds
        warningThresholdPercent = defaults.object(forKey: Keys.warningThresholdPercent) as? Double ?? defaultValues.warningThresholdPercent
        criticalThresholdPercent = defaults.object(forKey: Keys.criticalThresholdPercent) as? Double ?? defaultValues.criticalThresholdPercent
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? defaultValues.notificationsEnabled

        let migratedMode = defaults.string(forKey: Keys.statusDisplayMode)
        showPrimaryWindowInStatusBar = defaults.object(forKey: Keys.showPrimaryWindowInStatusBar) as? Bool
            ?? (migratedMode != "secondaryOnly")
        showSecondaryWindowInStatusBar = defaults.object(forKey: Keys.showSecondaryWindowInStatusBar) as? Bool
            ?? (migratedMode != "primaryOnly")
        showStatusBarWindowLabels = defaults.object(forKey: Keys.showStatusBarWindowLabels) as? Bool ?? defaultValues.showStatusBarWindowLabels
        usageTrendRangeDays = defaults.object(forKey: Keys.usageTrendRangeDays) as? Int ?? defaultValues.usageTrendRangeDays

    }

    func reset() {
        Keys.all.forEach { defaults.removeObject(forKey: $0) }

        let defaultValues = DefaultValues.current
        codexHomePath = defaultValues.codexHomePath
        refreshIntervalSeconds = defaultValues.refreshIntervalSeconds
        warningThresholdPercent = defaultValues.warningThresholdPercent
        criticalThresholdPercent = defaultValues.criticalThresholdPercent
        notificationsEnabled = defaultValues.notificationsEnabled
        showPrimaryWindowInStatusBar = defaultValues.showPrimaryWindowInStatusBar
        showSecondaryWindowInStatusBar = defaultValues.showSecondaryWindowInStatusBar
        showStatusBarWindowLabels = defaultValues.showStatusBarWindowLabels
        usageTrendRangeDays = defaultValues.usageTrendRangeDays
    }

    private enum Keys {
        static let codexHomePath = "codexHomePath"
        static let refreshIntervalSeconds = "refreshIntervalSeconds"
        static let warningThresholdPercent = "warningThresholdPercent"
        static let criticalThresholdPercent = "criticalThresholdPercent"
        static let notificationsEnabled = "notificationsEnabled"
        static let statusDisplayMode = "statusDisplayMode"
        static let showPrimaryWindowInStatusBar = "showPrimaryWindowInStatusBar"
        static let showSecondaryWindowInStatusBar = "showSecondaryWindowInStatusBar"
        static let showStatusBarWindowLabels = "showStatusBarWindowLabels"
        static let usageTrendRangeDays = "usageTrendRangeDays"

        static let all = [
            codexHomePath,
            refreshIntervalSeconds,
            warningThresholdPercent,
            criticalThresholdPercent,
            notificationsEnabled,
            statusDisplayMode,
            showPrimaryWindowInStatusBar,
            showSecondaryWindowInStatusBar,
            showStatusBarWindowLabels,
            usageTrendRangeDays
        ]
    }

    private struct DefaultValues {
        var codexHomePath: String
        var refreshIntervalSeconds: Double
        var warningThresholdPercent: Double
        var criticalThresholdPercent: Double
        var notificationsEnabled: Bool
        var showPrimaryWindowInStatusBar: Bool
        var showSecondaryWindowInStatusBar: Bool
        var showStatusBarWindowLabels: Bool
        var usageTrendRangeDays: Int

        static var current: DefaultValues {
            DefaultValues(
                codexHomePath: FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".codex")
                    .path,
                refreshIntervalSeconds: 60,
                warningThresholdPercent: 25,
                criticalThresholdPercent: 10,
                notificationsEnabled: true,
                showPrimaryWindowInStatusBar: true,
                showSecondaryWindowInStatusBar: true,
                showStatusBarWindowLabels: true,
                usageTrendRangeDays: 30
            )
        }
    }
}
