import Foundation
import Testing
@testable import CodexUsage

@Suite("Usage trend chart")
@MainActor
struct UsageTrendChartTests {
    @Test("Selected-range daily average includes zero-usage days")
    func selectedRangeAverageIncludesZeroUsageDays() {
        let points = [
            UsageTrendPoint(capturedAt: Date(timeIntervalSince1970: 0), totalTokens: 900),
            UsageTrendPoint(capturedAt: Date(timeIntervalSince1970: 86_400), totalTokens: 0),
            UsageTrendPoint(capturedAt: Date(timeIntervalSince1970: 172_800), totalTokens: 0)
        ]

        #expect(UsageTrendChartView.averageTokens(in: points) == 300)
    }

    @Test("An empty selected range has a zero daily average")
    func emptyRangeAverageIsZero() {
        #expect(UsageTrendChartView.averageTokens(in: []) == 0)
    }
}
