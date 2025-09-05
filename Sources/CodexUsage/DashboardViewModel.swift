import Foundation

@MainActor
final class DashboardViewModel: ObservableObject {
    @Published var snapshot: CodexUsageSnapshot
    @Published var trendPoints: [UsageTrendPoint] = []
    @Published var isRefreshing = false
    @Published var lastError: String?

    private let provider: UsageProvider
    private let sharedStore: SharedSnapshotStore
    private let notificationManager: NotificationManager
    private var refreshTask: Task<Void, Never>?

    init(
        provider: UsageProvider = CodexJSONLUsageProvider(),
        sharedStore: SharedSnapshotStore = SharedSnapshotStore(),
        notificationManager: NotificationManager = NotificationManager()
    ) {
        self.provider = provider
        self.sharedStore = sharedStore
        self.notificationManager = notificationManager
        snapshot = sharedStore.load() ?? .empty
    }

    deinit {
        refreshTask?.cancel()
    }

    func startAutoRefresh(settings: AppSettings) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self, weak settings] in
            guard let self, let settings else { return }

            await notificationManager.requestAuthorizationIfNeeded(enabled: settings.notificationsEnabled)

            while !Task.isCancelled {
                await self.refresh(settings: settings)

                let delay = max(15, settings.refreshIntervalSeconds)
                do {
                    try await Task.sleep(for: .seconds(delay))
                } catch {
                    return
                }
            }
        }
    }

    func refresh(settings: AppSettings) async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let codexHomePath = settings.codexHomePath
        let warningThreshold = settings.warningThresholdPercent
        let criticalThreshold = settings.criticalThresholdPercent
        let notificationsEnabled = settings.notificationsEnabled
        let provider = provider

        do {
            let nextSnapshot = try await Task.detached(priority: .userInitiated) {
                try await provider.fetchLatestSnapshot(codexHomePath: codexHomePath)
            }.value

            snapshot = nextSnapshot
            lastError = nil
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

            trendPoints = try await Task.detached(priority: .utility) {
                try provider.fetchTrendPoints(
                    codexHomePath: codexHomePath,
                    relativeTo: nextSnapshot.capturedAt
                )
            }.value
        } catch {
            lastError = error.localizedDescription
        }
    }
}
