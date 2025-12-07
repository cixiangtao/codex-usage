import Foundation
import UserNotifications

enum DebugNotificationDelivery {
    case appBundle
    case developmentPreview
}

@MainActor
final class NotificationManager {
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard
    ) {
        self.defaults = defaults
    }

    func requestAuthorizationIfNeeded(enabled: Bool) async {
        guard enabled, isRunningFromAppBundle else { return }

        do {
            _ = try await requestAuthorization()
        } catch {
            // Notification permission failure should not block the menu bar app.
        }
    }

    func sendDebugNotification(
        window: RateWindow,
        health: UsageHealth
    ) async throws -> DebugNotificationDelivery {
        let title = notificationTitle(health: health)
        let body = notificationBody(window: window)

        guard isRunningFromAppBundle else {
            try deliverDevelopmentPreview(title: title, body: body)
            return .developmentPreview
        }

        guard try await requestAuthorization() else {
            throw DeliveryError.permissionDenied
        }

        try await deliver(
            identifier: "codex-usage-debug-\(UUID().uuidString)",
            title: title,
            body: body
        )

        return .appBundle
    }

    func notifyIfNeeded(
        snapshot: CodexUsageSnapshot,
        health: UsageHealth,
        notificationsEnabled: Bool
    ) async {
        guard isRunningFromAppBundle,
              notificationsEnabled else {
            return
        }

        let previousHealth = defaults.string(forKey: Keys.lastUsageHealth)
            .flatMap(UsageHealth.init(rawValue:))
        defaults.set(health.rawValue, forKey: Keys.lastUsageHealth)
        defaults.removeObject(forKey: Keys.lastRefreshFailureKey)

        if health == .warning || health == .critical,
           let constrainedWindow = snapshot.mostConstrainedWindow {
            await notifyLowQuotaIfNeeded(window: constrainedWindow, health: health)
        } else if health == .normal,
                  previousHealth == .warning || previousHealth == .critical,
                  let recoveredWindow = snapshot.mostConstrainedWindow {
            await notifyQuotaRecoveredIfNeeded(window: recoveredWindow)
        }

        await notifyResetCardExpiryIfNeeded(info: snapshot.resetCards)
    }

    func notifyRefreshFailureIfNeeded(error: Error, notificationsEnabled: Bool) async {
        guard isRunningFromAppBundle,
              notificationsEnabled else {
            return
        }

        let message = error.localizedDescription
        let dedupeKey = "refresh-failure-\(message)"
        guard defaults.string(forKey: Keys.lastRefreshFailureKey) != dedupeKey else {
            return
        }

        do {
            try await deliver(
                identifier: "codex-usage-\(dedupeKey)",
                title: "Codex 用量刷新失败",
                body: "\(message)。已保留上一次快照。"
            )
            defaults.set(dedupeKey, forKey: Keys.lastRefreshFailureKey)
        } catch {
            // Keep refresh healthy even if notification delivery fails.
        }
    }

    private func notifyLowQuotaIfNeeded(window: RateWindow, health: UsageHealth) async {
        let remaining = window.remainingPercent
        let resetKey = Int(window.resetsAt?.timeIntervalSince1970 ?? 0)
        let dedupeKey = "\(health.rawValue)-\(resetKey)-\(Int(remaining.rounded()))"

        guard defaults.string(forKey: Keys.lastNotificationKey) != dedupeKey else {
            return
        }

        do {
            try await deliver(
                identifier: "codex-usage-\(dedupeKey)",
                title: notificationTitle(health: health),
                body: notificationBody(window: window)
            )
            defaults.set(dedupeKey, forKey: Keys.lastNotificationKey)
        } catch {
            // Keep refresh healthy even if notification delivery fails.
        }
    }

    private func notifyQuotaRecoveredIfNeeded(window: RateWindow) async {
        let resetKey = Int(window.resetsAt?.timeIntervalSince1970 ?? 0)
        let dedupeKey = "recovered-\(resetKey)-\(Int(window.remainingPercent.rounded()))"

        guard defaults.string(forKey: Keys.lastRecoveryNotificationKey) != dedupeKey else {
            return
        }

        do {
            try await deliver(
                identifier: "codex-usage-\(dedupeKey)",
                title: "Codex 额度已恢复",
                body: "\(window.displayName) 当前剩余 \(UsageFormatters.percent(window.remainingPercent))。"
            )
            defaults.set(dedupeKey, forKey: Keys.lastRecoveryNotificationKey)
        } catch {
            // Keep refresh healthy even if notification delivery fails.
        }
    }

    private func notifyResetCardExpiryIfNeeded(info: ResetCardInfo?) async {
        guard let info,
              info.unlimited == false,
              (info.balance ?? 0) > 0,
              let expiresAt = info.expiresAt else {
            return
        }

        let secondsUntilExpiry = expiresAt.timeIntervalSinceNow
        guard secondsUntilExpiry > 0, secondsUntilExpiry <= 86_400 else {
            return
        }

        let dedupeKey = "reset-card-expiry-\(Int(expiresAt.timeIntervalSince1970))-\(info.balance ?? 0)"
        guard defaults.string(forKey: Keys.lastResetCardExpiryNotificationKey) != dedupeKey else {
            return
        }

        do {
            try await deliver(
                identifier: "codex-usage-\(dedupeKey)",
                title: "Codex 重置卡即将过期",
                body: "剩余 \(info.balance ?? 0) 次，约 \(UsageFormatters.relativeDateString(for: expiresAt))后过期。"
            )
            defaults.set(dedupeKey, forKey: Keys.lastResetCardExpiryNotificationKey)
        } catch {
            // Keep refresh healthy even if notification delivery fails.
        }
    }

    private func requestAuthorization() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        return try await center.requestAuthorization(options: [.alert, .sound])
    }

    private func notificationTitle(health: UsageHealth) -> String {
        health == .critical ? "Codex 用量快满了" : "Codex 剩余额度偏低"
    }

    private func notificationBody(window: RateWindow) -> String {
        "\(window.displayName) 剩余 \(UsageFormatters.percent(window.remainingPercent))，\(UsageFormatters.resetText(window.resetsAt))"
    }

    private nonisolated func deliver(identifier: String, title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        try await center.add(request)
    }

    private nonisolated func deliverDevelopmentPreview(title: String, body: String) throws {
        let source = "display notification \(appleScriptString(body)) with title \(appleScriptString(title)) sound name \"default\""
        guard let script = NSAppleScript(source: source) else {
            throw DeliveryError.developmentPreviewFailed
        }

        var error: NSDictionary?
        script.executeAndReturnError(&error)

        if error != nil {
            throw DeliveryError.developmentPreviewFailed
        }
    }

    private nonisolated func appleScriptString(_ value: String) -> String {
        let escapedValue = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        return "\"\(escapedValue)\""
    }

    private enum Keys {
        static let lastNotificationKey = "lastNotificationKey"
        static let lastUsageHealth = "lastUsageHealth"
        static let lastRecoveryNotificationKey = "lastRecoveryNotificationKey"
        static let lastResetCardExpiryNotificationKey = "lastResetCardExpiryNotificationKey"
        static let lastRefreshFailureKey = "lastRefreshFailureKey"
    }

    private enum DeliveryError: LocalizedError {
        case developmentPreviewFailed
        case permissionDenied

        var errorDescription: String? {
            switch self {
            case .developmentPreviewFailed:
                "开发预览通知发送失败，请检查系统通知设置是否允许脚本编辑器或终端发送通知。"
            case .permissionDenied:
                "macOS 通知权限未开启，请在系统设置里允许 CodexUsage 发送通知。"
            }
        }
    }

    private var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }
}
