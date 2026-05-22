import Foundation
import Testing
@testable import CodexUsage

@Suite("Codex rate window identity")
struct RateWindowKindTests {
    @Test("Older reset card snapshots decode without disclosure details")
    func decodesLegacyResetCardInfo() throws {
        let data = Data(
            """
            {
              "hasCards": true,
              "unlimited": false,
              "balance": 2,
              "expiresAt": 812851200
            }
            """.utf8
        )

        let info = try JSONDecoder().decode(ResetCardInfo.self, from: data)

        #expect(info.balance == 2)
        #expect(info.cards == nil)
    }

    @Test("A seven-day primary API slot is treated as the seven-day window")
    func classifiesSevenDayWindowByDuration() {
        let sevenDayWindow = RateWindow(
            name: "7d",
            usedPercent: 42,
            windowMinutes: 7 * 24 * 60,
            resetsAt: nil
        )
        let snapshot = makeSnapshot(primary: sevenDayWindow, secondary: nil)

        #expect(CodexRateWindowKind.primary.window(in: snapshot) == nil)
        #expect(CodexRateWindowKind.secondary.window(in: snapshot) == sevenDayWindow)
    }

    @Test("Normal API slots retain their duration-based identities")
    func classifiesBothWindowsByDuration() {
        let fiveHourWindow = RateWindow(
            name: "5h",
            usedPercent: 21,
            windowMinutes: 5 * 60,
            resetsAt: nil
        )
        let sevenDayWindow = RateWindow(
            name: "7d",
            usedPercent: 37,
            windowMinutes: 7 * 24 * 60,
            resetsAt: nil
        )
        let snapshot = makeSnapshot(primary: sevenDayWindow, secondary: fiveHourWindow)

        #expect(CodexRateWindowKind.primary.window(in: snapshot) == fiveHourWindow)
        #expect(CodexRateWindowKind.secondary.window(in: snapshot) == sevenDayWindow)
    }

    @Test("Legacy snapshots without durations keep positional compatibility")
    func fallsBackToPositionWithoutDuration() {
        let primaryWindow = RateWindow(
            name: "5h",
            usedPercent: 10,
            windowMinutes: nil,
            resetsAt: nil
        )
        let secondaryWindow = RateWindow(
            name: "7d",
            usedPercent: 20,
            windowMinutes: nil,
            resetsAt: nil
        )
        let snapshot = makeSnapshot(primary: primaryWindow, secondary: secondaryWindow)

        #expect(CodexRateWindowKind.primary.window(in: snapshot) == primaryWindow)
        #expect(CodexRateWindowKind.secondary.window(in: snapshot) == secondaryWindow)
    }

    @Test("Disabling the five-hour status item keeps an available seven-day window visible")
    @MainActor
    func fiveHourToggleDoesNotControlSevenDayWindow() {
        let sevenDayWindow = RateWindow(
            name: "7d",
            usedPercent: 42,
            windowMinutes: 7 * 24 * 60,
            resetsAt: nil
        )
        let snapshot = makeSnapshot(primary: sevenDayWindow, secondary: nil)

        let bothEnabled = StatusBarLabel(
            snapshot: snapshot,
            health: .normal,
            showPrimary: true,
            showSecondary: true,
            showLabels: true
        )
        let fiveHourDisabled = StatusBarLabel(
            snapshot: snapshot,
            health: .normal,
            showPrimary: false,
            showSecondary: true,
            showLabels: true
        )
        let sevenDayDisabled = StatusBarLabel(
            snapshot: snapshot,
            health: .normal,
            showPrimary: true,
            showSecondary: false,
            showLabels: true
        )

        #expect(bothEnabled.labelText == "7d 58%")
        #expect(fiveHourDisabled.labelText == "7d 58%")
        #expect(sevenDayDisabled.labelText.isEmpty)
    }

    private func makeSnapshot(primary: RateWindow?, secondary: RateWindow?) -> CodexUsageSnapshot {
        CodexUsageSnapshot(
            capturedAt: Date(),
            accountIdentifier: nil,
            planType: nil,
            limitId: nil,
            primary: primary,
            secondary: secondary,
            resetCards: nil,
            tokenUsage: .empty,
            source: "test"
        )
    }
}
