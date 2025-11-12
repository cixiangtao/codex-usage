import Foundation
import SQLite3

protocol UsageProvider: Sendable {
    func fetchLatestSnapshot(codexHomePath: String) async throws -> CodexUsageSnapshot
    func fetchTrendPoints(codexHomePath: String, relativeTo date: Date) async throws -> [UsageTrendPoint]
}

struct CodexUsageProvider: UsageProvider {
    private let generalUsageLimitId = "codex"
    private let maxBytesPerFile = UInt64(600_000)
    private let maxTrendDays = 30

    func fetchLatestSnapshot(codexHomePath: String) async throws -> CodexUsageSnapshot {
        let localSnapshot = try fetchLatestLocalSnapshot(codexHomePath: codexHomePath)

        guard var remoteSnapshot = try? await fetchLatestRemoteSnapshot(codexHomePath: codexHomePath) else {
            return localSnapshot
        }

        if remoteSnapshot.accountIdentifier == nil {
            remoteSnapshot.accountIdentifier = localSnapshot.accountIdentifier
        }
        remoteSnapshot.tokenUsage = localSnapshot.tokenUsage
        if remoteSnapshot.resetCards?.expiresAt == nil {
            remoteSnapshot.resetCards?.expiresAt = localSnapshot.resetCards?.expiresAt
        }

        return remoteSnapshot
    }

    private func fetchLatestLocalSnapshot(codexHomePath: String) throws -> CodexUsageSnapshot {
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

    private func fetchLatestRemoteSnapshot(codexHomePath: String) async throws -> CodexUsageSnapshot {
        let credentials = try loadAuthCredentials(codexHomePath: codexHomePath)
        let usage = try await fetchRemoteUsage(credentials: credentials)
        let resetCards = try? await fetchRemoteResetCards(credentials: credentials)
        guard let snapshot = makeRemoteSnapshot(from: usage, resetCards: resetCards) else {
            throw UsageProviderError.noRemoteRateLimits
        }

        var snapshotWithAccount = snapshot
        snapshotWithAccount.accountIdentifier = usage.accountIdentifier ?? credentials.loginIdentifier
        return snapshotWithAccount
    }

    private func fetchRemoteUsage(credentials: CodexAuthCredentials) async throws -> CodexUsageAPIResponse {
        let data = try await fetchRemoteUsageData(credentials: credentials)
        return try JSONDecoder().decode(CodexUsageAPIResponse.self, from: data)
    }

    private func fetchRemoteUsageData(credentials: CodexAuthCredentials) async throws -> Data {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 8
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsage/1.0", forHTTPHeaderField: "User-Agent")

        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw UsageProviderError.remoteStatusCode((response as? HTTPURLResponse)?.statusCode ?? -1)
        }

        return data
    }

    private func fetchRemoteResetCards(credentials: CodexAuthCredentials) async throws -> ResetCardInfo? {
        let url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 4
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexUsage/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")

        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-ID")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let payload = try JSONDecoder().decode(CodexRateLimitResetCreditsResponse.self, from: data)

        return ResetCardInfo(
            hasCards: payload.availableCount > 0,
            unlimited: false,
            balance: payload.availableCount,
            expiresAt: payload.expiresAt
        )
    }

    private func loadAuthCredentials(codexHomePath: String) throws -> CodexAuthCredentials {
        let authURL = URL(fileURLWithPath: codexHomePath)
            .appendingPathComponent("auth.json")

        let data = try Data(contentsOf: authURL)
        let auth = try JSONDecoder().decode(CodexAuthFile.self, from: data)
        guard let accessToken = auth.tokens?.accessToken, !accessToken.isEmpty else {
            throw UsageProviderError.missingAuthToken
        }

        return CodexAuthCredentials(
            accessToken: accessToken,
            accountId: auth.tokens?.accountId,
            loginIdentifier: auth.tokens?.loginIdentifier
        )
    }

    func fetchTrendPoints(codexHomePath: String, relativeTo date: Date) async throws -> [UsageTrendPoint] {
        if let remotePoints = try? await fetchRemoteTrendPoints(codexHomePath: codexHomePath, relativeTo: date),
           !remotePoints.isEmpty {
            return remotePoints
        }

        return try fetchLocalTrendPoints(codexHomePath: codexHomePath, relativeTo: date)
    }

    private func fetchRemoteTrendPoints(codexHomePath: String, relativeTo date: Date) async throws
        -> [UsageTrendPoint]?
    {
        let credentials = try loadAuthCredentials(codexHomePath: codexHomePath)
        let data = try await fetchRemoteUsageData(credentials: credentials)
        return remoteTrendPoints(from: data, relativeTo: date)
    }

    private func fetchLocalTrendPoints(codexHomePath: String, relativeTo date: Date) throws -> [UsageTrendPoint] {
        let sessionRoots = codexSessionRoots(codexHomePath: codexHomePath)
        guard !sessionRoots.isEmpty else {
            return []
        }

        let accountScope = currentLocalAccountScope(codexHomePath: codexHomePath)
        let jsonlTrend = try fetchJSONLTrendPoints(
            sessionRoots: sessionRoots,
            accountScope: accountScope,
            relativeTo: date
        )
        if !jsonlTrend.points.isEmpty {
            return jsonlTrend.points
        }

        if accountScope != nil, jsonlTrend.sawTokenEvents {
            return []
        }

        if let threadTrendPoints = try fetchThreadTrendPoints(codexHomePath: codexHomePath, relativeTo: date) {
            return threadTrendPoints
        }

        return []
    }

    private func codexSessionRoots(codexHomePath: String) -> [URL] {
        let codexHomeURL = URL(fileURLWithPath: codexHomePath)
        let fileManager = FileManager.default

        return [
            codexHomeURL.appendingPathComponent("sessions", isDirectory: true),
            codexHomeURL.appendingPathComponent("archived_sessions", isDirectory: true)
        ].filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    private func fetchJSONLTrendPoints(
        sessionRoots: [URL],
        accountScope: LocalAccountScope?,
        relativeTo date: Date
    ) throws -> JSONLTrendResult {
        let files = try sessionRoots.flatMap { try recentJSONLFiles(in: $0) }
        let cutoffDate = trendCutoffDate(relativeTo: date)
        var events: [ParsedTokenEvent] = []
        var sawTokenEvents = false
        for file in files where file.modifiedAt >= cutoffDate {
            let generalEvents = try tokenEvents(in: file.url, mode: .fullFile)
                .filter { isGeneralUsageLimit($0.snapshot) }
            if !generalEvents.isEmpty {
                sawTokenEvents = true
            }
            events.append(contentsOf: generalEvents.filter { isInCurrentLocalAccountScope($0.snapshot, scope: accountScope) })
        }

        let sortedEvents = events.sorted { $0.timestamp < $1.timestamp }
        return JSONLTrendResult(
            points: dailyTrendPoints(from: sortedEvents, cutoffDate: cutoffDate),
            sawTokenEvents: sawTokenEvents
        )
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

                if let event = parseTokenEvent(from: line, sourceURL: file.url),
                   isGeneralUsageLimit(event.snapshot) {
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
            accountIdentifier: firstStringValue(
                in: [
                    rateLimits,
                    payload,
                    info
                ],
                keys: [
                    "email",
                    "user_email",
                    "userEmail",
                    "phone_number",
                    "phoneNumber",
                    "phone"
                ]
            ),
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
            resetCards: parseResetCards(rateLimits?["credits"] as? [String: Any]),
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

    private func parseResetCards(_ object: [String: Any]?) -> ResetCardInfo? {
        guard let object else { return nil }

        return ResetCardInfo(
            hasCards: optionalBoolValue(object["has_credits"]),
            unlimited: boolValue(object["unlimited"]),
            balance: optionalIntValue(object["balance"]),
            expiresAt: firstDateValue(
                in: object,
                keys: [
                    "expires_at",
                    "expiresAt",
                    "expiration",
                    "expiration_at",
                    "expiration_date",
                    "valid_until",
                    "validUntil"
                ]
            )
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

    private func makeRemoteSnapshot(
        from response: CodexUsageAPIResponse,
        resetCards: ResetCardInfo?
    ) -> CodexUsageSnapshot? {
        let primary = makeRemoteWindow(response.rateLimit?.primaryWindow, kind: .primary)
        let secondary = makeRemoteWindow(response.rateLimit?.secondaryWindow, kind: .secondary)
        guard primary != nil || secondary != nil || resetCards != nil || response.credits != nil else {
            return nil
        }

        return CodexUsageSnapshot(
            capturedAt: Date(),
            accountIdentifier: response.accountIdentifier,
            planType: response.planType,
            limitId: generalUsageLimitId,
            primary: primary,
            secondary: secondary,
            resetCards: resetCards ?? makeRemoteCreditCards(response.credits),
            tokenUsage: .empty,
            source: "OpenAI OAuth API"
        )
    }

    private func makeRemoteWindow(_ window: CodexUsageAPIResponse.RateLimitWindow?, kind: CodexRateWindowKind)
        -> RateWindow?
    {
        guard let window else {
            return nil
        }

        let windowMinutes = window.limitWindowSeconds.map { $0 / 60 }
        return RateWindow(
            name: windowMinutes.map(CodexRateWindowKind.displayName(minutes:)) ?? kind.defaultDisplayName,
            usedPercent: window.usedPercent,
            windowMinutes: windowMinutes,
            resetsAt: window.resetAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    private func makeRemoteCreditCards(_ credits: CodexUsageAPIResponse.Credits?) -> ResetCardInfo? {
        guard let credits else {
            return nil
        }

        return ResetCardInfo(
            hasCards: credits.hasCredits,
            unlimited: credits.unlimited,
            balance: credits.balance,
            expiresAt: credits.expiresAt
        )
    }

    private func isGeneralUsageLimit(_ snapshot: CodexUsageSnapshot) -> Bool {
        snapshot.limitId == generalUsageLimitId
    }

    private func currentLocalAccountScope(codexHomePath: String) -> LocalAccountScope? {
        guard let credentials = try? loadAuthCredentials(codexHomePath: codexHomePath) else {
            return nil
        }

        let identifiers = [
            credentials.accountId,
            credentials.loginIdentifier
        ].compactMap(normalizedAccountIdentifier)

        guard !identifiers.isEmpty else {
            return nil
        }

        return LocalAccountScope(identifiers: Set(identifiers))
    }

    private func isInCurrentLocalAccountScope(_ snapshot: CodexUsageSnapshot, scope: LocalAccountScope?) -> Bool {
        guard let scope else {
            return true
        }

        if let accountIdentifier = normalizedAccountIdentifier(snapshot.accountIdentifier) {
            return scope.identifiers.contains(accountIdentifier)
        }

        return hasQuotaContext(snapshot)
    }

    private func hasQuotaContext(_ snapshot: CodexUsageSnapshot) -> Bool {
        snapshot.planType != nil || snapshot.primary != nil || snapshot.secondary != nil || snapshot.resetCards != nil
    }

    private func normalizedAccountIdentifier(_ value: String?) -> String? {
        guard let value = optionalStringValue(value) else {
            return nil
        }

        return value.lowercased()
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

    private func remoteTrendPoints(from data: Data, relativeTo date: Date) -> [UsageTrendPoint]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        var totalsByDay: [Date: Int] = [:]
        collectRemoteDailyTokenTotals(from: root, into: &totalsByDay)
        guard !totalsByDay.isEmpty else {
            return nil
        }

        let calendar = Calendar.current
        let latestDay = calendar.startOfDay(for: date)
        let startOffset = -(maxTrendDays - 1)
        guard let firstDay = calendar.date(byAdding: .day, value: startOffset, to: latestDay) else {
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

    private func collectRemoteDailyTokenTotals(from value: Any, into totalsByDay: inout [Date: Int]) {
        if let array = value as? [Any] {
            for item in array {
                collectRemoteDailyTokenTotals(from: item, into: &totalsByDay)
            }
            return
        }

        guard let object = value as? [String: Any] else {
            return
        }

        if let day = firstDateValue(
            in: object,
            keys: ["day", "date", "captured_at", "capturedAt", "created_at", "createdAt"]
        ),
           let totalTokens = firstIntValue(
               in: object,
               keys: ["total_tokens", "totalTokens", "tokens_used", "tokensUsed"]
           ),
           totalTokens > 0 {
            totalsByDay[Calendar.current.startOfDay(for: day), default: 0] += totalTokens
        }

        for nested in object.values {
            collectRemoteDailyTokenTotals(from: nested, into: &totalsByDay)
        }
    }

    private func firstIntValue(in object: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = optionalIntValue(object[key]) {
                return value
            }
        }

        return nil
    }

    private func firstStringValue(in objects: [[String: Any]?], keys: [String]) -> String? {
        for object in objects.compactMap({ $0 }) {
            if let value = firstStringValue(in: object, keys: keys) {
                return value
            }
        }

        return nil
    }

    private func firstStringValue(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = optionalStringValue(object[key]) {
                return value
            }
        }

        return nil
    }

    private func optionalStringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        return nil
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

    private func boolValue(_ value: Any?) -> Bool {
        optionalBoolValue(value) ?? false
    }

    private func optionalBoolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool {
            return value
        }

        if let value = value as? Int {
            return value != 0
        }

        if let value = value as? Double {
            return value != 0
        }

        if let value = value as? String {
            switch value.lowercased() {
            case "true", "yes", "1":
                return true
            case "false", "no", "0":
                return false
            default:
                return nil
            }
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

    private func firstDateValue(in object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let date = dateValue(object[key]) {
                return date
            }
        }

        return nil
    }

    private func dateValue(_ value: Any?) -> Date? {
        if let seconds = doubleValue(value) {
            return Date(timeIntervalSince1970: seconds)
        }

        if let value = value as? String {
            return DateParsers.parse(value)
        }

        return nil
    }
}

private struct ParsedTokenEvent {
    var timestamp: Date
    var tokenDelta: Int
    var snapshot: CodexUsageSnapshot
}

private struct JSONLTrendResult {
    var points: [UsageTrendPoint]
    var sawTokenEvents: Bool
}

private struct LocalAccountScope {
    var identifiers: Set<String>
}

private struct CodexAuthFile: Decodable {
    var tokens: CodexAuthTokens?
}

private struct CodexAuthTokens: Decodable {
    var accessToken: String?
    var accountId: String?
    var idToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case accountId = "account_id"
        case idToken = "id_token"
    }

    var loginIdentifier: String? {
        guard let idToken else { return nil }
        return JWTClaims.decode(from: idToken)?.loginIdentifier
    }
}

private struct CodexAuthCredentials {
    var accessToken: String
    var accountId: String?
    var loginIdentifier: String?
}

private struct JWTClaims: Decodable {
    var email: String?
    var phoneNumber: String?

    private enum CodingKeys: String, CodingKey {
        case email
        case phoneNumber = "phone_number"
    }

    var loginIdentifier: String? {
        if let email = trimmed(email) {
            return email
        }

        return trimmed(phoneNumber)
    }

    static func decode(from token: String) -> JWTClaims? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2,
              let payloadData = Data(base64URLEncoded: String(segments[1])) else {
            return nil
        }

        return try? JSONDecoder().decode(JWTClaims.self, from: payloadData)
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }

        return value
    }
}

private struct CodexUsageAPIResponse: Decodable {
    var accountIdentifier: String?
    var planType: String?
    var rateLimit: RateLimit?
    var credits: Credits?

    private enum CodingKeys: String, CodingKey {
        case email
        case userEmail = "user_email"
        case userEmailCamel = "userEmail"
        case phoneNumber = "phone_number"
        case phoneNumberCamel = "phoneNumber"
        case phone
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case credits
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountIdentifier = Self.decodeFirstString(
            container,
            keys: [.email, .userEmail, .userEmailCamel, .phoneNumber, .phoneNumberCamel, .phone]
        )
        planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        credits = try? container.decodeIfPresent(Credits.self, forKey: .credits)
    }

    private static func decodeFirstString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> String? {
        for key in keys {
            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        return nil
    }

    struct RateLimit: Decodable {
        var primaryWindow: RateLimitWindow?
        var secondaryWindow: RateLimitWindow?

        private enum CodingKeys: String, CodingKey {
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            primaryWindow = try? container.decodeIfPresent(RateLimitWindow.self, forKey: .primaryWindow)
            secondaryWindow = try? container.decodeIfPresent(RateLimitWindow.self, forKey: .secondaryWindow)
        }
    }

    struct RateLimitWindow: Decodable {
        var usedPercent: Double
        var resetAt: Int?
        var limitWindowSeconds: Int?

        private enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case resetAt = "reset_at"
            case limitWindowSeconds = "limit_window_seconds"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            guard let usedPercent = Self.decodeFlexibleDouble(container, forKey: .usedPercent) else {
                throw DecodingError.keyNotFound(
                    CodingKeys.usedPercent,
                    DecodingError.Context(
                        codingPath: decoder.codingPath,
                        debugDescription: "Missing used_percent"
                    )
                )
            }

            self.usedPercent = usedPercent
            resetAt = Self.decodeFlexibleInt(container, forKey: .resetAt)
            limitWindowSeconds = Self.decodeFlexibleInt(container, forKey: .limitWindowSeconds)
        }

        private static func decodeFlexibleDouble(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Double? {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return value
            }

            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return Double(value)
            }

            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Double(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            return nil
        }

        private static func decodeFlexibleInt(
            _ container: KeyedDecodingContainer<CodingKeys>,
            forKey key: CodingKeys
        ) -> Int? {
            if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
                return value
            }

            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                return Int(value)
            }

            if let value = try? container.decodeIfPresent(String.self, forKey: key) {
                return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            return nil
        }
    }

    struct Credits: Decodable {
        var hasCredits: Bool?
        var unlimited: Bool
        var balance: Int?
        var expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case balance
            case expiresAt = "expires_at"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            hasCredits = try? container.decodeIfPresent(Bool.self, forKey: .hasCredits)
            unlimited = (try? container.decodeIfPresent(Bool.self, forKey: .unlimited)) ?? false
            if let value = try? container.decodeIfPresent(Int.self, forKey: .balance) {
                balance = value
            } else if let value = try? container.decodeIfPresent(Double.self, forKey: .balance) {
                balance = Int(value)
            } else if let value = try? container.decodeIfPresent(String.self, forKey: .balance) {
                balance = Int(value)
            } else {
                balance = nil
            }
            expiresAt = FlexibleDateDecoding.decode(container, forKey: .expiresAt)
        }
    }
}

private struct CodexRateLimitResetCreditsResponse: Decodable {
    var availableCount: Int
    var expiresAt: Date?

    private enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case credits
        case expiresAt = "expires_at"
        case expiresAtCamel = "expiresAt"
        case expiration
        case expirationAt = "expiration_at"
        case expirationDate = "expiration_date"
        case validUntil = "valid_until"
        case validUntilCamel = "validUntil"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let value = try? container.decode(Int.self, forKey: .availableCount) {
            availableCount = value
        } else if let value = try? container.decode(String.self, forKey: .availableCount) {
            availableCount = Int(value) ?? 0
        } else {
            availableCount = 0
        }

        let credits = (try? container.decodeIfPresent([Credit].self, forKey: .credits)) ?? []
        expiresAt = Self.decodeFlexibleDate(
            container,
            keys: [
                .expiresAt,
                .expiresAtCamel,
                .expiration,
                .expirationAt,
                .expirationDate,
                .validUntil,
                .validUntilCamel
            ]
        ) ?? Self.availableExpiresAt(from: credits)
    }

    private static func availableExpiresAt(from credits: [Credit]) -> Date? {
        let availableDates = credits
            .filter(\.isAvailable)
            .compactMap(\.expiresAt)

        if let earliestAvailableDate = availableDates.min() {
            return earliestAvailableDate
        }

        return credits.compactMap(\.expiresAt).min()
    }

    private static func decodeFlexibleDate(
        _ container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Date? {
        for key in keys {
            if let date = FlexibleDateDecoding.decode(container, forKey: key) {
                return date
            }
        }

        return nil
    }

    private struct Credit: Decodable {
        var status: String?
        var expiresAt: Date?

        private enum CodingKeys: String, CodingKey {
            case status
            case expiresAt = "expires_at"
            case expiresAtCamel = "expiresAt"
            case expiration
            case expirationAt = "expiration_at"
            case expirationDate = "expiration_date"
            case validUntil = "valid_until"
            case validUntilCamel = "validUntil"
        }

        var isAvailable: Bool {
            status?.lowercased() == "available"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try? container.decodeIfPresent(String.self, forKey: .status)
            expiresAt = Self.decodeFlexibleDate(
                container,
                keys: [
                    .expiresAt,
                    .expiresAtCamel,
                    .expiration,
                    .expirationAt,
                    .expirationDate,
                    .validUntil,
                    .validUntilCamel
                ]
            )
        }

        private static func decodeFlexibleDate(
            _ container: KeyedDecodingContainer<CodingKeys>,
            keys: [CodingKeys]
        ) -> Date? {
            for key in keys {
                if let date = FlexibleDateDecoding.decode(container, forKey: key) {
                    return date
                }
            }

            return nil
        }
    }
}

private enum UsageProviderError: LocalizedError {
    case missingAuthToken
    case noRemoteRateLimits
    case remoteStatusCode(Int)

    var errorDescription: String? {
        switch self {
        case .missingAuthToken:
            "Codex auth.json exists but does not contain an access token."
        case .noRemoteRateLimits:
            "OpenAI Codex usage API returned no rate-limit windows."
        case let .remoteStatusCode(statusCode):
            "OpenAI Codex usage API returned HTTP \(statusCode)."
        }
    }
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

private enum FlexibleDateDecoding {
    static func decode<Key: CodingKey>(
        _ container: KeyedDecodingContainer<Key>,
        forKey key: Key
    ) -> Date? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return Date(timeIntervalSince1970: value)
        }

        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }

        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            if let seconds = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return Date(timeIntervalSince1970: seconds)
            }

            return DateParsers.parse(value)
        }

        return nil
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }

        self.init(base64Encoded: base64)
    }
}
