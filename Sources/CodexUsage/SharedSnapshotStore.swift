import Foundation

struct SharedSnapshotStore {
    static let appGroupIdentifier = "group.com.anys.codexusage"
    private static let snapshotKey = "latestCodexUsageSnapshot"

    func save(_ snapshot: CodexUsageSnapshot) {
        guard let data = try? JSONEncoder.codexUsage.encode(snapshot) else {
            return
        }

        UserDefaults.standard.set(data, forKey: Self.snapshotKey)
        UserDefaults(suiteName: Self.appGroupIdentifier)?.set(data, forKey: Self.snapshotKey)
    }

    func load() -> CodexUsageSnapshot? {
        let defaults = UserDefaults(suiteName: Self.appGroupIdentifier) ?? .standard
        guard let data = defaults.data(forKey: Self.snapshotKey) else {
            return nil
        }

        return try? JSONDecoder.codexUsage.decode(CodexUsageSnapshot.self, from: data)
    }
}

extension JSONEncoder {
    static var codexUsage: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var codexUsage: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
