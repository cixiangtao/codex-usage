import Foundation
import SQLite3

protocol UsageProvider: Sendable {
    func fetchLatestSnapshot(codexHomePath: String) throws -> CodexUsageSnapshot
    func fetchTrendPoints(codexHomePath: String, relativeTo date: Date) throws -> [UsageTrendPoint]
}

struct CodexJSONLUsageProvider: UsageProvider {
    private let maxBytesPerFile = UInt64(600_000)
    private let maxTrendDays = 30

    func fetchLatestSnapshot(codexHomePath: String) throws -> CodexUsageSnapshot {
        let sessionsURL = URL(fileURLWithPath: codexHomePath)
            .appendingPathComponent("sessions", isDirectory: true)

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            return .empty
        }

        let files = try recentJSONLFiles(in: sessionsURL)
        guard let newest = try newestTokenEvent(in: files) else {
            return .empty
        }

        return newest.snapshot
    }

    func fetchTrendPoints(codexHomePath: String, relativeTo date: Date) throws -> [UsageTrendPoint] {
        let sessionsURL = URL(fileURLWithPath: codexHomePath)
            .appendingPathComponent("sessions", isDirectory: true)

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: sessionsURL.path) else {
            return []
        }

        if let threadTrendPoints = try fetchThreadTrendPoints(codexHomePath: codexHomePath, relativeTo: date) {
            return threadTrendPoints
        }

        let files = try recentJSONLFiles(in: sessionsURL)
        let cutoffDate = trendCutoffDate(relativeTo: date)
        var events: [ParsedTokenEvent] = []
        for file in files where file.modifiedAt >= cutoffDate {
            events.append(contentsOf: try tokenEvents(in: file.url, mode: .fullFile))
        }

        let sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
        return dailyTrendPoints(from: sortedEvents, cutoffDate: cutoffDate)
    }

    private func fetchThreadTrendPoints(codexHomePath: String, relativeTo date: Date) throws -> [UsageTrendPoint]? {
        let databaseURL = URL(fileURLWithPath: codexHomePath)
            .appendingPathComponent("state_5.sqlite")
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        var database: OpaquePointer?
        let openFlags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &database, openFlags, nil) == SQLITE_OK,
              let database else {
            return nil
        }
        defer { sqlite3_close(database) }

        let calendar = Calendar.current
        let latestDay = calendar.startOfDay(for: date)
        let startOffset = -(maxTrendDays - 1)
        guard let firstDay = calendar.date(byAdding: .day, value: startOffset, to: latestDay),
              let endDate = calendar.date(byAdding: .day, value: 1, to: latestDay) else {
            return nil
        }

        let query = """
            SELECT created_at, tokens_used
            FROM threads
            WHERE tokens_used > 0
              AND created_at >= ?
              AND created_at < ?
            ORDER BY created_at ASC
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            return nil
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, Int64(firstDay.timeIntervalSince1970))
        sqlite3_bind_int64(statement, 2, Int64(endDate.timeIntervalSince1970))

        var totalsByDay: [Date: Int] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            let createdAt = sqlite3_column_int64(statement, 0)
            let tokensUsed = Int(sqlite3_column_int64(statement, 1))
            let day = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(createdAt)))
            totalsByDay[day, default: 0] += tokensUsed
        }

        guard !totalsByDay.isEmpty else {
            return nil
        }

        return (0..<maxTrendDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                return nil
            }

            return UsageTrendPoint(
                capturedAt: day,
                totalTokens: totalsByDay[day, default: 0]
            )
        }
    }

    private func recentJSONLFiles(in sessionsURL: URL) throws -> [JSONLFile] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [JSONLFile] = []

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            candidates.append(JSONLFile(url: url, modifiedAt: values?.contentModificationDate ?? .distantPast))
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func newestTokenEvent(in files: [JSONLFile]) throws -> ParsedTokenEvent? {
        for file in files {
            for line in try lines(from: file.url, mode: .tail).reversed() {
                guard line.contains("\"token_count\"") else {
                    continue
                }

                if let event = parseTokenEvent(from: line, sourceURL: file.url) {
                    return event
                }
            }
        }

        return nil
    }

    private func tokenEvents(in file: URL, mode: JSONLReadMode) throws -> [ParsedTokenEvent] {
        try lines(from: file, mode: mode).compactMap { line in
            guard line.contains("\"token_count\"") else {
                return nil
            }

            return parseTokenEvent(from: line, sourceURL: file)
        }
    }

    private func lines(from url: URL, mode: JSONLReadMode) throws -> [Substring] {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let size = try handle.seekToEnd()
        if mode == .tail, size > maxBytesPerFile {
            try handle.seek(toOffset: size - maxBytesPerFile)
        } else {
            try handle.seek(toOffset: 0)
        }

        let data = handle.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8) else {
            return []
        }

        return text.split(separator: "\n", omittingEmptySubsequences: true)
    }

    private func trendCutoffDate(relativeTo date: Date) -> Date {
        Calendar.current.date(byAdding: .day, value: -maxTrendDays, to: date) ?? .distantPast
    }

    private func parseTokenEvent(from line: Substring, sourceURL: URL) -> ParsedTokenEvent? {
        guard let data = String(line).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestampString = root["timestamp"] as? String,
              let timestamp = DateParsers.parse(timestampString),
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else {
            return nil
        }

        let rateLimits = payload["rate_limits"] as? [String: Any]
        let tokenUsage = parseTokenUsage(info["total_token_usage"] as? [String: Any])
        let lastTokenUsage = parseTokenUsage(info["last_token_usage"] as? [String: Any])

        let snapshot = CodexUsageSnapshot(
            capturedAt: timestamp,
            planType: rateLimits?["plan_type"] as? String,
            limitId: rateLimits?["limit_id"] as? String,
            primary: parseWindow(
                rateLimits?["primary"] as? [String: Any],
                kind: .primary
            ),
            secondary: parseWindow(
                rateLimits?["secondary"] as? [String: Any],
                kind: .secondary
            ),
            tokenUsage: tokenUsage,
            source: sourceURL.lastPathComponent
        )

        return ParsedTokenEvent(
            timestamp: timestamp,
            tokenDelta: lastTokenUsage.totalTokens,
            snapshot: snapshot
        )
    }

    private func parseTokenUsage(_ object: [String: Any]?) -> TokenUsage {
        TokenUsage(
            inputTokens: intValue(object?["input_tokens"]),
            cachedInputTokens: intValue(object?["cached_input_tokens"]),
            outputTokens: intValue(object?["output_tokens"]),
            reasoningOutputTokens: intValue(object?["reasoning_output_tokens"]),
            totalTokens: intValue(object?["total_tokens"])
        )
    }

    private func parseWindow(_ object: [String: Any]?, kind: CodexRateWindowKind) -> RateWindow? {
        guard let object, let usedPercent = doubleValue(object["used_percent"]) else {
            return nil
        }

        let resetSeconds = doubleValue(object["resets_at"])
        let windowMinutes = optionalIntValue(object["window_minutes"])

        return RateWindow(
            name: windowMinutes.map(CodexRateWindowKind.displayName(minutes:)) ?? kind.defaultDisplayName,
            usedPercent: usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: resetSeconds.map { Date(timeIntervalSince1970: $0) }
        )
    }

    private func dailyTrendPoints(from events: [ParsedTokenEvent], cutoffDate: Date) -> [UsageTrendPoint] {
        let calendar = Calendar.current
        var totalsByDay: [Date: Int] = [:]

        for event in events where event.timestamp >= cutoffDate && event.tokenDelta > 0 {
            let day = calendar.startOfDay(for: event.timestamp)
            totalsByDay[day, default: 0] += event.tokenDelta
        }

        guard let latestDay = totalsByDay.keys.max() else {
            return []
        }

        let startOffset = -(maxTrendDays - 1)
        guard let firstDay = calendar.date(byAdding: .day, value: startOffset, to: latestDay) else {
            return []
        }

        return (0..<maxTrendDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else {
                return nil
            }

            return UsageTrendPoint(
                capturedAt: day,
                totalTokens: totalsByDay[day, default: 0]
            )
        }
    }

    private func intValue(_ value: Any?) -> Int {
        optionalIntValue(value) ?? 0
    }

    private func optionalIntValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }

        if let value = value as? Double {
            return Int(value)
        }

        if let value = value as? String {
            return Int(value)
        }

        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let value = value as? Double {
            return value
        }

        if let value = value as? Int {
            return Double(value)
        }

        if let value = value as? String {
            return Double(value)
        }

        return nil
    }
}

private struct ParsedTokenEvent {
    var timestamp: Date
    var tokenDelta: Int
    var snapshot: CodexUsageSnapshot
}

private struct JSONLFile {
    var url: URL
    var modifiedAt: Date
}

private enum JSONLReadMode {
    case fullFile
    case tail
}

private enum DateParsers {
    static func parse(_ value: String) -> Date? {
        let iso8601WithFractionalSeconds = ISO8601DateFormatter()
        iso8601WithFractionalSeconds.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = iso8601WithFractionalSeconds.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
