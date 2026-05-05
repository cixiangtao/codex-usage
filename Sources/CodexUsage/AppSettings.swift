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

    @Published var statusBarIconID: String {
        didSet { defaults.set(statusBarIconID, forKey: Keys.statusBarIconID) }
    }

    @Published var animateStatusBarIcon: Bool {
        didSet { defaults.set(animateStatusBarIcon, forKey: Keys.animateStatusBarIcon) }
    }

    @Published var statusBarAnimationFollowsCPU: Bool {
        didSet {
            defaults.set(
                statusBarAnimationFollowsCPU,
                forKey: Keys.statusBarAnimationFollowsCPU
            )
        }
    }

    @Published var statusBarAnimationBaseSpeeds: [String: Double] {
        didSet {
            if let data = try? JSONEncoder().encode(statusBarAnimationBaseSpeeds) {
                defaults.set(data, forKey: Keys.statusBarAnimationBaseSpeeds)
            }
        }
    }

    @Published var customStatusBarIcons: [CustomStatusBarIcon] {
        didSet {
            if let data = try? JSONEncoder().encode(customStatusBarIcons) {
                defaults.set(data, forKey: Keys.customStatusBarIcons)
            }
        }
    }

    @Published var usageTrendRangeDays: Int {
        didSet { defaults.set(usageTrendRangeDays, forKey: Keys.usageTrendRangeDays) }
    }

    private let defaults: UserDefaults
    let customIconDirectory: URL

    init(
        defaults: UserDefaults = .standard,
        customIconDirectory: URL? = nil
    ) {
        self.defaults = defaults
        self.customIconDirectory = customIconDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CodexUsage/StatusBarIcons", isDirectory: true)
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
        let legacyIconID = defaults.string(forKey: Keys.statusBarIconStyle)
        statusBarIconID = defaults.string(forKey: Keys.statusBarIconID)
            ?? legacyIconID
            ?? defaultValues.statusBarIconID
        animateStatusBarIcon = defaults.object(forKey: Keys.animateStatusBarIcon) as? Bool
            ?? defaultValues.animateStatusBarIcon
        statusBarAnimationFollowsCPU = defaults.object(
            forKey: Keys.statusBarAnimationFollowsCPU
        ) as? Bool
            ?? defaultValues.statusBarAnimationFollowsCPU
        statusBarAnimationBaseSpeeds = defaults.data(
            forKey: Keys.statusBarAnimationBaseSpeeds
        )
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) }
            ?? [:]
        customStatusBarIcons = defaults.data(forKey: Keys.customStatusBarIcons)
            .flatMap { try? JSONDecoder().decode([CustomStatusBarIcon].self, from: $0) }
            ?? []
        usageTrendRangeDays = defaults.object(forKey: Keys.usageTrendRangeDays) as? Int ?? defaultValues.usageTrendRangeDays

    }

    var statusBarIconStyle: StatusBarIconStyle {
        get { StatusBarIconStyle(rawValue: statusBarIconID) ?? .adaptive }
        set { statusBarIconID = newValue.rawValue }
    }

    var selectedStatusBarIcon: StatusBarIconDescriptor {
        StatusBarIconCatalog.descriptor(
            id: statusBarIconID,
            customIcons: customStatusBarIcons,
            customIconDirectory: customIconDirectory
        )
    }

    func statusBarAnimationBaseSpeed(for iconID: String) -> Double {
        StatusBarAnimationTiming.clampedBaseSpeed(
            statusBarAnimationBaseSpeeds[iconID] ?? 1
        )
    }

    func setStatusBarAnimationBaseSpeed(_ speed: Double, for iconID: String) {
        var speeds = statusBarAnimationBaseSpeeds
        let clampedSpeed = StatusBarAnimationTiming.clampedBaseSpeed(speed)

        if abs(clampedSpeed - 1) < 0.001 {
            speeds.removeValue(forKey: iconID)
        } else {
            speeds[iconID] = clampedSpeed
        }
        statusBarAnimationBaseSpeeds = speeds
    }

    @discardableResult
    func importStatusBarIcon(from sourceURL: URL) throws -> CustomStatusBarIcon {
        let icon = try CustomStatusBarIconStore.importIcon(
            from: sourceURL,
            into: customIconDirectory
        )
        customStatusBarIcons.append(icon)
        statusBarIconID = icon.catalogID
        return icon
    }

    func removeStatusBarIcon(_ icon: CustomStatusBarIcon) throws {
        try CustomStatusBarIconStore.remove(icon, from: customIconDirectory)
        customStatusBarIcons.removeAll { $0.id == icon.id }
        statusBarAnimationBaseSpeeds.removeValue(forKey: icon.catalogID)
        if statusBarIconID == icon.catalogID {
            statusBarIconID = StatusBarIconCatalog.defaultID
        }
    }

    func reset() {
        for icon in customStatusBarIcons {
            try? CustomStatusBarIconStore.remove(icon, from: customIconDirectory)
        }
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
        statusBarIconID = defaultValues.statusBarIconID
        animateStatusBarIcon = defaultValues.animateStatusBarIcon
        statusBarAnimationFollowsCPU = defaultValues.statusBarAnimationFollowsCPU
        statusBarAnimationBaseSpeeds = [:]
        customStatusBarIcons = []
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
        static let statusBarIconStyle = "statusBarIconStyle"
        static let statusBarIconID = "statusBarIconID"
        static let animateStatusBarIcon = "animateStatusBarIcon"
        static let statusBarAnimationFollowsCPU = "statusBarAnimationFollowsCPU"
        static let statusBarAnimationBaseSpeeds = "statusBarAnimationBaseSpeeds"
        static let customStatusBarIcons = "customStatusBarIcons"
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
            statusBarIconStyle,
            statusBarIconID,
            animateStatusBarIcon,
            statusBarAnimationFollowsCPU,
            statusBarAnimationBaseSpeeds,
            customStatusBarIcons,
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
        var statusBarIconID: String
        var animateStatusBarIcon: Bool
        var statusBarAnimationFollowsCPU: Bool
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
                statusBarIconID: StatusBarIconCatalog.defaultID,
                animateStatusBarIcon: true,
                statusBarAnimationFollowsCPU: true,
                usageTrendRangeDays: 30
            )
        }
    }
}
