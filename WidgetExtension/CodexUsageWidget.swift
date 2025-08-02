import SwiftUI
import WidgetKit

struct CodexUsageWidget: Widget {
    let kind = "CodexUsageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            CodexUsageWidgetView(entry: entry)
        }
        .configurationDisplayName("Codex 用量")
        .description("显示本地 Codex 最新剩余额度快照。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) {
        completion(Entry(date: Date(), snapshot: SnapshotStore().load() ?? .placeholder))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = Entry(date: Date(), snapshot: SnapshotStore().load() ?? .placeholder)
        let nextRefresh = Calendar.current.date(byAdding: .minute, value: 5, to: Date()) ?? Date().addingTimeInterval(300)
        completion(Timeline(entries: [entry], policy: .after(nextRefresh)))
    }
}

struct Entry: TimelineEntry {
    var date: Date
    var snapshot: CodexUsageSnapshot
}

struct CodexUsageWidgetView: View {
    var entry: Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "bolt.circle")
                Text("Codex")
                    .font(.headline)
                Spacer()
            }

            Text(percent(entry.snapshot.constrainedRemainingPercent))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .monospacedDigit()

            ProgressView(value: progress)
                .tint(tint)

            Text(resetText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
        .containerBackground(.background, for: .widget)
        .padding()
    }

    private var progress: Double {
        guard let remaining = entry.snapshot.constrainedRemainingPercent else {
            return 0
        }
        return max(0, min(1, remaining / 100))
    }

    private var tint: Color {
        guard let remaining = entry.snapshot.constrainedRemainingPercent else {
            return .secondary
        }

        if remaining <= 10 {
            return .red
        }

        if remaining <= 25 {
            return .orange
        }

        return .green
    }

    private var resetText: String {
        guard let date = entry.snapshot.mostConstrainedWindow?.resetsAt else {
            return "等待本地 Codex 数据"
        }

        return "\(relativeDateString(for: date))后重置"
    }

    private func relativeDateString(for date: Date) -> String {
        let seconds = Int(abs(date.timeIntervalSinceNow).rounded())

        if seconds < 60 {
            return "\(max(1, seconds)) 秒"
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return "\(minutes) 分钟"
        }

        let hours = minutes / 60
        if hours < 48 {
            return "\(hours) 小时"
        }

        return "\(hours / 24) 天"
    }

    private func percent(_ value: Double?) -> String {
        guard let value else { return "--%" }
        return "\(Int(value.rounded()))%"
    }
}

struct SnapshotStore {
    static let appGroupIdentifier = "group.com.anys.codexusage"
    private static let snapshotKey = "latestCodexUsageSnapshot"

    func load() -> CodexUsageSnapshot? {
        let defaults = UserDefaults(suiteName: Self.appGroupIdentifier)
        guard let data = defaults?.data(forKey: Self.snapshotKey) else {
            return nil
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CodexUsageSnapshot.self, from: data)
    }
}

struct CodexUsageSnapshot: Codable, Equatable {
    var capturedAt: Date
    var planType: String?
    var limitId: String?
    var primary: RateWindow?
    var secondary: RateWindow?
    var tokenUsage: TokenUsage
    var source: String

    static let placeholder = CodexUsageSnapshot(
        capturedAt: Date(),
        planType: "pro",
        limitId: "codex",
        primary: RateWindow(name: "5h", usedPercent: 35, windowMinutes: 300, resetsAt: Date().addingTimeInterval(3600)),
        secondary: RateWindow(name: "7d", usedPercent: 52, windowMinutes: 10080, resetsAt: Date().addingTimeInterval(86_400)),
        tokenUsage: TokenUsage(inputTokens: 0, cachedInputTokens: 0, outputTokens: 0, reasoningOutputTokens: 0, totalTokens: 0),
        source: "占位数据"
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

struct RateWindow: Codable, Equatable, Identifiable {
    var id: String { name }
    var name: String
    var usedPercent: Double
    var windowMinutes: Int?
    var resetsAt: Date?

    var remainingPercent: Double {
        max(0, 100 - usedPercent)
    }
}

struct TokenUsage: Codable, Equatable {
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningOutputTokens: Int
    var totalTokens: Int
}

@main
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexUsageWidget()
    }
}
