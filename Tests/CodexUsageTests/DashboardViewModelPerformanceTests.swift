import Foundation
import Testing
@testable import CodexUsage

@Suite("Dashboard view model performance contracts", .serialized)
struct DashboardViewModelPerformanceTests {
    @Test("Automatic quota refresh does not fetch trend data")
    @MainActor
    func autoRefreshSkipsTrendFetch() async {
        let fixture = SettingsFixture(codexHomePath: "/tmp/codex-usage-auto-refresh")
        defer { fixture.remove() }
        fixture.settings.refreshIntervalSeconds = 900
        fixture.settings.notificationsEnabled = false

        let provider = DashboardUsageProviderSpy(snapshotShouldFail: true)
        let viewModel = DashboardViewModel(
            provider: provider,
            notificationManager: NotificationManager(defaults: fixture.defaults)
        )

        viewModel.startAutoRefresh(settings: fixture.settings)
        defer { viewModel.stopAutoRefresh() }

        let didCompleteQuotaRefresh = await eventually {
            viewModel.lastError == DashboardUsageProviderSpy.snapshotFailureDescription
        }
        #expect(didCompleteQuotaRefresh)

        try? await Task.sleep(for: .milliseconds(25))
        #expect(await provider.snapshotCallCount() == 1)
        #expect(await provider.trendCallCount() == 0)
    }

    @Test("Scheduled trend refresh is single-flight and outlives its caller task")
    @MainActor
    func scheduledTrendRefreshOutlivesCaller() async {
        let fixture = SettingsFixture(codexHomePath: "/tmp/codex-usage-scheduled-trend")
        defer { fixture.remove() }

        let expectedPoints = [
            UsageTrendPoint(capturedAt: Date(timeIntervalSince1970: 1_722_182_400), totalTokens: 42)
        ]
        let provider = DashboardUsageProviderSpy(
            trendResponses: [expectedPoints],
            blocksTrendRequests: true
        )
        let viewModel = DashboardViewModel(
            provider: provider,
            notificationManager: NotificationManager(defaults: fixture.defaults)
        )

        let caller = Task { @MainActor in
            viewModel.scheduleTrendRefresh(settings: fixture.settings)
            try? await Task.sleep(for: .seconds(30))
        }

        let didStartTrendRefresh = await eventually {
            await provider.trendCallCount() == 1
        }
        #expect(didStartTrendRefresh)

        caller.cancel()
        await caller.value

        viewModel.scheduleTrendRefresh(settings: fixture.settings)
        try? await Task.sleep(for: .milliseconds(25))
        #expect(await provider.trendCallCount() == 1)

        await provider.releaseBlockedTrendRequests()

        let didPublishTrend = await eventually {
            viewModel.trendPoints == expectedPoints
        }
        #expect(didPublishTrend)
        #expect(await provider.trendCallCount() == 1)
    }

    @Test("Trend refresh honors its ten-minute TTL and supports forced refresh")
    @MainActor
    func trendRefreshTTLAndForce() async {
        let fixture = SettingsFixture(codexHomePath: "/tmp/codex-usage-trend-ttl")
        defer { fixture.remove() }

        let firstPoints = [
            UsageTrendPoint(capturedAt: Date(timeIntervalSince1970: 1_722_182_400), totalTokens: 10)
        ]
        let forcedPoints = [
            UsageTrendPoint(capturedAt: Date(timeIntervalSince1970: 1_722_268_800), totalTokens: 25)
        ]
        let changedPathPoints = [
            UsageTrendPoint(capturedAt: Date(timeIntervalSince1970: 1_722_355_200), totalTokens: 50)
        ]
        let provider = DashboardUsageProviderSpy(
            trendResponses: [firstPoints, forcedPoints, changedPathPoints]
        )
        let viewModel = DashboardViewModel(
            provider: provider,
            notificationManager: NotificationManager(defaults: fixture.defaults),
            trendRefreshInterval: 10 * 60
        )

        await viewModel.refreshTrendIfNeeded(settings: fixture.settings)
        await viewModel.refreshTrendIfNeeded(settings: fixture.settings)

        #expect(await provider.trendCallCount() == 1)
        #expect(viewModel.trendPoints == firstPoints)

        await viewModel.refreshTrendIfNeeded(settings: fixture.settings, force: true)

        #expect(await provider.trendCallCount() == 2)
        #expect(viewModel.trendPoints == forcedPoints)

        fixture.settings.codexHomePath = "/tmp/codex-usage-trend-ttl-other-home"
        await viewModel.refreshTrendIfNeeded(settings: fixture.settings)

        #expect(await provider.trendCallCount() == 3)
        #expect(viewModel.trendPoints == changedPathPoints)
    }

    @Test("Trend cache expires immediately when the local calendar day changes")
    @MainActor
    func trendRefreshExpiresAtDayBoundary() async throws {
        let fixture = SettingsFixture(codexHomePath: "/tmp/codex-usage-trend-day-boundary")
        defer { fixture.remove() }

        let calendar = Calendar.current
        let firstDay = try #require(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 2,
            hour: 23,
            minute: 59
        )))
        let nextDay = try #require(calendar.date(byAdding: .minute, value: 2, to: firstDay))
        let clock = DashboardTestClock(now: firstDay)
        let provider = DashboardUsageProviderSpy(trendResponses: [[], []])
        let viewModel = DashboardViewModel(
            provider: provider,
            notificationManager: NotificationManager(defaults: fixture.defaults),
            trendRefreshInterval: 10 * 60,
            now: { clock.now }
        )

        await viewModel.refreshTrendIfNeeded(settings: fixture.settings)
        clock.now = nextDay
        await viewModel.refreshTrendIfNeeded(settings: fixture.settings)

        #expect(await provider.trendCallCount() == 2)
        #expect(await provider.trendReferenceDates() == [firstDay, nextDay])
    }

    @Test("A cold trend scan does not block quota refresh")
    @MainActor
    func trendAndQuotaUseIndependentProviders() async {
        let fixture = SettingsFixture(codexHomePath: "/tmp/codex-usage-independent-providers")
        defer { fixture.remove() }

        let quotaProvider = DashboardUsageProviderSpy(snapshotShouldFail: true)
        let trendProvider = DashboardUsageProviderSpy(blocksTrendRequests: true)
        let viewModel = DashboardViewModel(
            provider: quotaProvider,
            trendProvider: trendProvider,
            notificationManager: NotificationManager(defaults: fixture.defaults)
        )

        viewModel.scheduleTrendRefresh(settings: fixture.settings)
        let didStartTrendRefresh = await eventually {
            await trendProvider.trendCallCount() == 1
        }
        #expect(didStartTrendRefresh)

        await viewModel.refresh(settings: fixture.settings, includeTrend: false)
        #expect(await quotaProvider.snapshotCallCount() == 1)

        await trendProvider.releaseBlockedTrendRequests()
    }

    @MainActor
    private func eventually(
        timeout: Duration = .seconds(1),
        condition: @escaping () async -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)

        while clock.now < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(for: .milliseconds(5))
        }

        return await condition()
    }
}

@MainActor
private final class SettingsFixture {
    let defaults: UserDefaults
    let settings: AppSettings

    private let suiteName: String

    init(codexHomePath: String) {
        suiteName = "CodexUsageTests.DashboardViewModel.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        settings = AppSettings(defaults: defaults)
        settings.codexHomePath = codexHomePath
        settings.notificationsEnabled = false
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class DashboardTestClock: @unchecked Sendable {
    var now: Date

    init(now: Date) {
        self.now = now
    }
}

private actor DashboardUsageProviderSpy: UsageProvider {
    static let snapshotFailureDescription = "Snapshot refresh failed in test"

    private let snapshotShouldFail: Bool
    private let snapshot: CodexUsageSnapshot
    private let trendResponses: [[UsageTrendPoint]]
    private var blocksTrendRequests: Bool

    private var snapshotCalls = 0
    private var trendCalls = 0
    private var trendDates: [Date] = []
    private var blockedTrendContinuations: [CheckedContinuation<Void, Never>] = []

    init(
        snapshotShouldFail: Bool = false,
        snapshot: CodexUsageSnapshot = .empty,
        trendResponses: [[UsageTrendPoint]] = [[]],
        blocksTrendRequests: Bool = false
    ) {
        self.snapshotShouldFail = snapshotShouldFail
        self.snapshot = snapshot
        self.trendResponses = trendResponses
        self.blocksTrendRequests = blocksTrendRequests
    }

    func fetchLatestSnapshot(codexHomePath: String) async throws -> CodexUsageSnapshot {
        snapshotCalls += 1
        if snapshotShouldFail {
            throw SnapshotFailure()
        }
        return snapshot
    }

    func fetchTrendPoints(
        codexHomePath: String,
        relativeTo date: Date
    ) async throws -> [UsageTrendPoint] {
        trendCalls += 1
        trendDates.append(date)
        let responseIndex = min(trendCalls - 1, trendResponses.count - 1)
        let response = trendResponses[responseIndex]

        if blocksTrendRequests {
            await withCheckedContinuation { continuation in
                blockedTrendContinuations.append(continuation)
            }
        }

        try Task.checkCancellation()
        return response
    }

    func snapshotCallCount() -> Int {
        snapshotCalls
    }

    func trendCallCount() -> Int {
        trendCalls
    }

    func trendReferenceDates() -> [Date] {
        trendDates
    }

    func releaseBlockedTrendRequests() {
        blocksTrendRequests = false
        let continuations = blockedTrendContinuations
        blockedTrendContinuations.removeAll()
        continuations.forEach { $0.resume() }
    }

    private struct SnapshotFailure: LocalizedError {
        var errorDescription: String? {
            DashboardUsageProviderSpy.snapshotFailureDescription
        }
    }
}
