import Foundation

struct TokenUsage: Codable, Equatable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int

    static let empty = TokenUsage(
        inputTokens: 0,
        cachedInputTokens: 0,
        outputTokens: 0,
        reasoningOutputTokens: 0,
        totalTokens: 0
    )
}

struct UsageTrendPoint: Codable, Equatable, Identifiable {
    var id: String {
        "\(Int(capturedAt.timeIntervalSince1970))-\(totalTokens)"
    }

    var capturedAt: Date
    var totalTokens: Int
}

struct RateWindow: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }

    var displayName: String {
        windowMinutes.map(CodexRateWindowKind.displayName(minutes:)) ?? name
    }
}

struct ResetCardInfo: Codable, Equatable {
    var hasCards: Bool?
    var unlimited: Bool
    var balance: Int?
    var expiresAt: Date?
    var cards: [ResetCard]? = nil
}

struct ResetCard: Codable, Equatable {
    var status: String?
    var expiresAt: Date?
}

enum CodexRateWindowKind {
    case primary
    case secondary

    private var expectedWindowMinutes: Int {
        switch self {
        case .primary:
            5 * 60
        case .secondary:
            7 * 24 * 60
        }
    }

    var defaultDisplayName: String {
        switch self {
        case .primary:
            "5h"
        case .secondary:
            "7d"
        }
    }

    var settingsTitle: String {
        "显示 \(defaultDisplayName) 额度"
    }

    var exampleText: String {
        "\(defaultDisplayName) 86%"
    }

    func window(in snapshot: CodexUsageSnapshot) -> RateWindow? {
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        if let matchingWindow = windows.first(where: { $0.windowMinutes == expectedWindowMinutes }) {
            return matchingWindow
        }

        let positionalWindow = switch self {
        case .primary:
            snapshot.primary
        case .secondary:
            snapshot.secondary
        }

        // Older snapshots may not include a duration, so retain the API's
        // positional meaning only when there is no better semantic signal.
        return positionalWindow?.windowMinutes == nil ? positionalWindow : nil
    }

    static func displayName(minutes: Int) -> String {
        if minutes >= 1_440, minutes % 1_440 == 0 {
            return "\(minutes / 1_440)d"
        }

        if minutes >= 60, minutes % 60 == 0 {
            return "\(minutes / 60)h"
        }

        return "\(minutes)m"
    }
}

struct CodexUsageSnapshot: Codable, Equatable {
    var capturedAt: Date
    var accountIdentifier: String?
    var planType: String?
    var limitId: String?
    var primary: RateWindow?
    var secondary: RateWindow?
    var resetCards: ResetCardInfo?
    var tokenUsage: TokenUsage
    var source: String

    static let empty = CodexUsageSnapshot(
        capturedAt: Date(),
        accountIdentifier: nil,
        planType: nil,
        limitId: nil,
        primary: nil,
        secondary: nil,
        resetCards: nil,
        tokenUsage: .empty,
        source: "未找到 Codex 用量快照"
    )

    var constrainedRemainingPercent: Double? {
        let windows = [primary, secondary].compactMap { $0 }
        guard !windows.isEmpty else { return nil }
        return windows.map(\.remainingPercent).min()
    }

    var mostConstrainedWindow: RateWindow? {
        [primary, secondary]
            .compactMap { $0 }
            .min { $0.remainingPercent < $1.remainingPercent }
    }
}

enum UsageHealth: String {
    case unavailable
    case normal
    case warning
    case critical

    static func evaluate(snapshot: CodexUsageSnapshot, warning: Double, critical: Double) -> UsageHealth {
        guard let remaining = snapshot.constrainedRemainingPercent else {
            return .unavailable
        }

        if remaining <= critical {
            return .critical
        }

        if remaining <= warning {
            return .warning
        }

        return .normal
    }
}
