import Foundation
import Testing
@testable import CodexUsage

@Suite("App settings")
struct AppSettingsTests {
    @Test("Status bar icon choice persists and resets to adaptive")
    @MainActor
    func statusBarIconChoicePersistsAndResets() {
        let suiteName = "CodexUsageTests.AppSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        #expect(settings.statusBarIconStyle == .adaptive)

        settings.statusBarIconStyle = .pixelBot

        let reloadedSettings = AppSettings(defaults: defaults)
        #expect(reloadedSettings.statusBarIconStyle == .pixelBot)

        reloadedSettings.reset()
        #expect(reloadedSettings.statusBarIconStyle == .adaptive)
    }

    @Test("Unknown status bar icon values fall back safely")
    @MainActor
    func unknownStatusBarIconFallsBackToAdaptive() {
        let suiteName = "CodexUsageTests.AppSettings.Invalid.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("future-icon", forKey: "statusBarIconStyle")

        let settings = AppSettings(defaults: defaults)

        #expect(settings.statusBarIconStyle == .adaptive)
    }
}
