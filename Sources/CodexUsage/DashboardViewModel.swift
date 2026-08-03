import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var snapshot: CodexUsageSnapshot
    @Published var trendPoints: [UsageTrendPoint] = []
    @Published var isRefreshing = false
    @Published var lastError: String?

    private let quotaProvider: UsageProvider
    private let trendProvider: UsageProvider
    private let sharedStore: SharedSnapshotStore
    private let notificationManager: NotificationManager
    private let trendRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var refreshTask: Task<Void, Never>?
    private var trendRefreshTask: Task<Void, Never>?
    private var isRefreshingTrend = false
    private var lastTrendRefreshAt: Date?
    private var lastTrendCodexHomePath: String?

    init(
        provider: UsageProvider? = nil,
        trendProvider: UsageProvider? = nil,
        sharedStore: SharedSnapshotStore = SharedSnapshotStore(),
        notificationManager: NotificationManager = NotificationManager(),
        trendRefreshInterval: TimeInterval = 10 * 60,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        if let provider {
            quotaProvider = provider
            self.trendProvider = trendProvider ?? provider
        } else {
            quotaProvider = CodexUsageProvider()
            self.trendProvider = trendProvider ?? CodexUsageProvider()
        }
        self.sharedStore = sharedStore
        self.notificationManager = notificationManager
        self.trendRefreshInterval = max(60, trendRefreshInterval)
        self.now = now
        snapshot = sharedStore.load() ?? .empty
    }

    deinit {
        refreshTask?.cancel()
        trendRefreshTask?.cancel()
    }

    func startAutoRefresh(settings: AppSettings) {
        refreshTask?.cancel()
        let notificationManager = notificationManager
        let notificationsEnabled = settings.notificationsEnabled
        refreshTask = Task(priority: .utility) { [weak self, weak settings] in
            await notificationManager.requestAuthorizationIfNeeded(enabled: notificationsEnabled)

            while !Task.isCancelled {
                let delay: TimeInterval
                do {
                    guard let settings else { return }
                    await self?.refresh(settings: settings, includeTrend: false)
                    delay = max(15, settings.refreshIntervalSeconds)
                }

                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    func scheduleTrendRefresh(settings: AppSettings) {
        guard trendRefreshTask == nil else { return }

        trendRefreshTask = Task(priority: .utility) { [weak self, weak settings] in
            defer { self?.trendRefreshTask = nil }
            guard let settings else { return }
            await self?.refreshTrendIfNeeded(settings: settings)
        }
    }

    func refresh(settings: AppSettings, includeTrend: Bool = true) async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let codexHomePath = settings.codexHomePath
        let warningThreshold = settings.warningThresholdPercent
        let criticalThreshold = settings.criticalThresholdPercent
        let notificationsEnabled = settings.notificationsEnabled
        let provider = quotaProvider

        do {
            let nextSnapshot = try await provider.fetchLatestSnapshot(codexHomePath: codexHomePath)

            snapshot = nextSnapshot
            if lastError != nil {
                lastError = nil
            }
            sharedStore.save(nextSnapshot)

            let health = UsageHealth.evaluate(
                snapshot: nextSnapshot,
                warning: warningThreshold,
                critical: criticalThreshold
            )

            await notificationManager.notifyIfNeeded(
                snapshot: nextSnapshot,
                health: health,
                notificationsEnabled: notificationsEnabled
            )
        } catch {
            guard !Task.isCancelled else { return }
            lastError = error.localizedDescription
            await notificationManager.notifyRefreshFailureIfNeeded(
                error: error,
                notificationsEnabled: notificationsEnabled
            )
        }

        if includeTrend {
            await refreshTrendIfNeeded(settings: settings, force: true)
        }
    }

    func refreshTrendIfNeeded(settings: AppSettings, force: Bool = false) async {
        guard !isRefreshingTrend else { return }

        let codexHomePath = settings.codexHomePath
        let referenceDate = now()
        if !force,
           lastTrendCodexHomePath == codexHomePath,
           let lastTrendRefreshAt,
           Calendar.current.isDate(lastTrendRefreshAt, inSameDayAs: referenceDate),
           referenceDate.timeIntervalSince(lastTrendRefreshAt) < trendRefreshInterval {
            return
        }

        isRefreshingTrend = true
        defer { isRefreshingTrend = false }

        do {
            let nextPoints = try await trendProvider.fetchTrendPoints(
                codexHomePath: codexHomePath,
                relativeTo: referenceDate
            )
            if trendPoints != nextPoints {
                trendPoints = nextPoints
            }
            lastTrendCodexHomePath = codexHomePath
            lastTrendRefreshAt = referenceDate
        } catch is CancellationError {
            return
        } catch {
            // Quota refresh remains healthy and the last trend stays visible.
        }
    }
}
