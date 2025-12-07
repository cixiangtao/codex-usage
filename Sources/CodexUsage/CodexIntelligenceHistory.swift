import Foundation

struct CodexIntelligenceCheckHistoryEntry: Codable, Equatable, Identifiable {
    var id: UUID
    var capturedAt: Date
    var modelName: String
    var reasoningEffort: String
    var requestedCount: Int
    var completedCount: Int
    var correctCount: Int
    var averageReasoningTokens: Int?
    var averageTokensPerSecond: Double?
    var conclusionTitle: String

    var accuracyPercent: Int {
        guard completedCount > 0 else { return 0 }
        return Int((Double(correctCount) / Double(completedCount) * 100).rounded())
    }
}

struct CodexIntelligenceCheckHistoryStore {
    private static let key = "codexIntelligenceCheckHistory"
    private let defaults: UserDefaults
    private let maxEntries: Int

    init(defaults: UserDefaults = .standard, maxEntries: Int = 20) {
        self.defaults = defaults
        self.maxEntries = maxEntries
    }

    func load() -> [CodexIntelligenceCheckHistoryEntry] {
        guard let data = defaults.data(forKey: Self.key),
              let entries = try? JSONDecoder.codexUsage.decode([CodexIntelligenceCheckHistoryEntry].self, from: data) else {
            return []
        }

        return entries.sorted { $0.capturedAt > $1.capturedAt }
    }

    func appending(
        _ entry: CodexIntelligenceCheckHistoryEntry,
        to existingEntries: [CodexIntelligenceCheckHistoryEntry]
    ) -> [CodexIntelligenceCheckHistoryEntry] {
        let nextEntries = Array(([entry] + existingEntries)
            .sorted { $0.capturedAt > $1.capturedAt }
            .prefix(maxEntries))

        if let data = try? JSONEncoder.codexUsage.encode(nextEntries) {
            defaults.set(data, forKey: Self.key)
        }

        return nextEntries
    }
}
