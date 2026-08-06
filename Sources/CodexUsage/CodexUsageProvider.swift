import Foundation
import SQLite3

protocol UsageProvider: Sendable {
    func fetchLatestSnapshot(codexHomePath: String) async throws -> CodexUsageSnapshot
    func fetchTrendPoints(codexHomePath: String, relativeTo date: Date) async throws -> [UsageTrendPoint]
}

actor CodexUsageProvider: UsageProvider {
    private static let trendCacheSchemaVersion = 3
    private static let tokenCountMarker = Data("\"token_count\"".utf8)
    private static let sessionMetaMarker = Data("\"session_meta\"".utf8)
    private static let boundaryFingerprintByteCount = 4_096

    private let generalUsageLimitId = "codex"
    private let maxBytesPerFile = UInt64(600_000)
    private let maxTrendDays = 30
    private let session: URLSession
    private let streamChunkSize: Int
    private let trendCacheURL: URL

    private var loadedTrendCache: PersistedJSONLTrendCache?
    private var latestTrendMetrics = LocalTrendScanMetrics()

    init(
        session: URLSession = .shared,
        trendCacheURL: URL? = nil,
        streamChunkSize: Int = 256 * 1_024
    ) {
        self.session = session
        self.trendCacheURL = trendCacheURL ?? Self.defaultTrendCacheURL()
        self.streamChunkSize = max(4_096, streamChunkSize)
    }

    func fetchLatestSnapshot(codexHomePath: String) async throws -> CodexUsageSnapshot {
        do {
            return try await fetchLatestRemoteSnapshot(codexHomePath: codexHomePath)
        } catch {
            try Task.checkCancellation()
            return try fetchLatestLocalSnapshot(codexHomePath: codexHomePath)
        }
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
        async let usageRequest = fetchRemoteUsage(credentials: credentials)
        async let resetCardsRequest = fetchRemoteResetCards(credentials: credentials)

        let usage = try await usageRequest
        let resetCards: ResetCardInfo?
        do {
            resetCards = try await resetCardsRequest
        } catch {
            try Task.checkCancellation()
            resetCards = nil
        }
        try Task.checkCancellation()
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

        let (data, response) = try await session.data(for: request)
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

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            return nil
        }

        let payload = try JSONDecoder().decode(CodexRateLimitResetCreditsResponse.self, from: data)

        return ResetCardInfo(
            hasCards: payload.availableCount > 0,
            unlimited: false,
            balance: payload.availableCount,
            expiresAt: payload.expiresAt,
            cards: payload.cards
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
        try Task.checkCancellation()
        return try fetchLocalTrendPoints(codexHomePath: codexHomePath, relativeTo: date)
    }

    func lastTrendScanMetrics() -> LocalTrendScanMetrics {
        latestTrendMetrics
    }

    private func fetchLocalTrendPoints(codexHomePath: String, relativeTo date: Date) throws -> [UsageTrendPoint] {
        let sessionRoots = codexSessionRoots(codexHomePath: codexHomePath)
        if !sessionRoots.isEmpty {
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
        let discoveredFiles = try sessionRoots.flatMap { try recentJSONLFiles(in: $0) }
        let files = deduplicatedJSONLFiles(discoveredFiles)
        let calendar = Calendar.current
        let latestDay = calendar.startOfDay(for: date)
        guard let firstDay = calendar.date(byAdding: .day, value: -(maxTrendDays - 1), to: latestDay) else {
            latestTrendMetrics = LocalTrendScanMetrics()
            return JSONLTrendResult(points: [], sawTokenEvents: false)
        }

        let accountIdentifiers = accountScope?.identifiers.sorted() ?? []
        let calendarIdentifier = String(describing: calendar.identifier)
        let timeZoneIdentifier = calendar.timeZone.identifier
        var cache = loadTrendCache(
            codexHomePath: sessionRoots[0].deletingLastPathComponent().path,
            accountIdentifiers: accountIdentifiers,
            calendarIdentifier: calendarIdentifier,
            timeZoneIdentifier: timeZoneIdentifier
        )
        let originalCache = cache
        var nextFiles: [String: CachedJSONLFile] = [:]
        var metrics = LocalTrendScanMetrics(discoveredFileCount: discoveredFiles.count)

        for file in files {
            try Task.checkCancellation()

            let existing = cache.files[file.cacheKey]
            let nextEntry = try autoreleasepool { () throws -> CachedJSONLFile in
                if file.modifiedAt < firstDay {
                    metrics.baselinedFileCount += existing == nil ? 1 : 0
                    metrics.reusedFileCount += existing == nil ? 0 : 1
                    return try baselineCacheEntry(for: file, reusing: existing)
                }

                return try refreshedCacheEntry(
                    for: file,
                    existing: existing,
                    accountScope: accountScope,
                    firstDay: firstDay,
                    metrics: &metrics
                )
            }

            nextFiles[file.cacheKey] = nextEntry.pruningDays(before: firstDay)
        }

        // A recently active fork can point at a parent whose file has not changed
        // within the trend window. Load only those ancestor files so their copied
        // token prefix can still be recognized without rescanning every old log.
        var pendingParentSessionIDs = Set(
            files
                .filter { $0.modifiedAt >= firstDay }
                .compactMap { nextFiles[$0.cacheKey]?.parentSessionID }
        )
        var resolvedParentSessionIDs: Set<String> = []
        while let parentSessionID = pendingParentSessionIDs.subtracting(resolvedParentSessionIDs).first {
            resolvedParentSessionIDs.insert(parentSessionID)
            guard let parentFile = files.first(where: { $0.sessionID == parentSessionID }),
                  var parentEntry = nextFiles[parentFile.cacheKey] else {
                continue
            }

            if parentEntry.tokenRecords.isEmpty, parentFile.modifiedAt < firstDay {
                parentEntry = try refreshedCacheEntry(
                    for: parentFile,
                    existing: nil,
                    accountScope: accountScope,
                    firstDay: firstDay,
                    metrics: &metrics
                )
                nextFiles[parentFile.cacheKey] = parentEntry.pruningDays(before: firstDay)
            }

            if let ancestorSessionID = parentEntry.parentSessionID {
                pendingParentSessionIDs.insert(ancestorSessionID)
            }
        }

        cache.files = nextFiles
        loadedTrendCache = cache
        if cache != originalCache {
            persistTrendCache(cache)
        }

        var totalsByDay: [Date: Int] = [:]
        var sawTokenEvents = false
        for file in files where file.modifiedAt >= firstDay {
            guard let entry = nextFiles[file.cacheKey] else { continue }
            sawTokenEvents = sawTokenEvents || entry.sawTokenEvents
        }

        let copiedPrefixCounts = copiedTokenPrefixCounts(in: nextFiles)
        for file in files where file.modifiedAt >= firstDay {
            guard let entry = nextFiles[file.cacheKey] else { continue }
            let copiedPrefixCount = copiedPrefixCounts[file.cacheKey, default: 0]
            for record in entry.tokenRecords.dropFirst(copiedPrefixCount) where record.countedDelta > 0 {
                let dayTimestamp = record.dayTimestamp
                let total = record.countedDelta
                let day = Date(timeIntervalSince1970: TimeInterval(dayTimestamp))
                guard day >= firstDay, day <= latestDay else { continue }
                totalsByDay[day, default: 0] += total
            }
        }

        latestTrendMetrics = metrics
        return JSONLTrendResult(
            points: dailyTrendPoints(from: totalsByDay, firstDay: firstDay),
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
        let resourceKeys: [URLResourceKey] = [
            .contentModificationDateKey,
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .isRegularFileKey
        ]
        let resourceKeySet = Set(resourceKeys)
        guard let enumerator = fileManager.enumerator(
            at: sessionsURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [JSONLFile] = []

        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let candidate = autoreleasepool { () -> JSONLFile? in
                guard let values = try? url.resourceValues(forKeys: resourceKeySet),
                      values.isRegularFile == true else {
                    return nil
                }

                return JSONLFile(
                    url: url,
                    modifiedAt: values.contentModificationDate ?? .distantPast,
                    size: UInt64(max(0, values.fileSize ?? 0)),
                    fileIdentity: Self.fileIdentity(
                        values.fileResourceIdentifier,
                        fallbackURL: url
                    )
                )
            }
            if let candidate {
                candidates.append(candidate)
            }
        }

        return candidates
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private func deduplicatedJSONLFiles(_ files: [JSONLFile]) -> [JSONLFile] {
        var filesByCacheKey: [String: JSONLFile] = [:]

        for file in files {
            guard let existing = filesByCacheKey[file.cacheKey] else {
                filesByCacheKey[file.cacheKey] = file
                continue
            }

            if file.size > existing.size
                || (file.size == existing.size && file.modifiedAt > existing.modifiedAt)
            {
                filesByCacheKey[file.cacheKey] = file
            }
        }

        return filesByCacheKey.values.sorted { lhs, rhs in
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.cacheKey < rhs.cacheKey
        }
    }

    private func loadTrendCache(
        codexHomePath: String,
        accountIdentifiers: [String],
        calendarIdentifier: String,
        timeZoneIdentifier: String
    ) -> PersistedJSONLTrendCache {
        if let loadedTrendCache,
           loadedTrendCache.matches(
               schemaVersion: Self.trendCacheSchemaVersion,
               codexHomePath: codexHomePath,
               accountIdentifiers: accountIdentifiers,
               calendarIdentifier: calendarIdentifier,
               timeZoneIdentifier: timeZoneIdentifier
           ) {
            return loadedTrendCache
        }

        if let data = try? Data(contentsOf: trendCacheURL),
           let decoded = try? JSONDecoder().decode(PersistedJSONLTrendCache.self, from: data),
           decoded.matches(
               schemaVersion: Self.trendCacheSchemaVersion,
               codexHomePath: codexHomePath,
               accountIdentifiers: accountIdentifiers,
               calendarIdentifier: calendarIdentifier,
               timeZoneIdentifier: timeZoneIdentifier
           ) {
            loadedTrendCache = decoded
            return decoded
        }

        let emptyCache = PersistedJSONLTrendCache(
            schemaVersion: Self.trendCacheSchemaVersion,
            codexHomePath: codexHomePath,
            accountIdentifiers: accountIdentifiers,
            calendarIdentifier: calendarIdentifier,
            timeZoneIdentifier: timeZoneIdentifier,
            files: [:]
        )
        loadedTrendCache = emptyCache
        return emptyCache
    }

    private func persistTrendCache(_ cache: PersistedJSONLTrendCache) {
        guard let data = try? JSONEncoder().encode(cache) else {
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: trendCacheURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: trendCacheURL, options: .atomic)
        } catch {
            // The trend remains usable in memory when the derived cache cannot be persisted.
        }
    }

    private func baselineCacheEntry(
        for file: JSONLFile,
        reusing existing: CachedJSONLFile?
    ) throws -> CachedJSONLFile {
        if var existing,
           existing.fileIdentity == file.fileIdentity,
           existing.fileSize == file.size,
           existing.modifiedAt == file.modifiedAt.timeIntervalSince1970 {
            existing.path = file.url.path
            return existing
        }

        let parsedOffset: UInt64
        do {
            parsedOffset = try lastCompleteLineOffset(in: file.url, fileSize: file.size)
        } catch {
            try Task.checkCancellation()
            parsedOffset = 0
        }

        return CachedJSONLFile(
            path: file.url.path,
            fileIdentity: file.fileIdentity,
            fileSize: file.size,
            modifiedAt: file.modifiedAt.timeIntervalSince1970,
            parsedOffset: parsedOffset,
            parsedBoundaryFingerprint: nil,
            lastCumulativeTotalTokens: nil,
            lastTokenEventFingerprint: nil,
            sessionID: file.sessionID,
            parentSessionID: nil,
            tokenRecords: [],
            totalsByDay: [:],
            sawTokenEvents: false
        )
    }

    private func refreshedCacheEntry(
        for file: JSONLFile,
        existing: CachedJSONLFile?,
        accountScope: LocalAccountScope?,
        firstDay: Date,
        metrics: inout LocalTrendScanMetrics
    ) throws -> CachedJSONLFile {
        let modificationTime = file.modifiedAt.timeIntervalSince1970
        if var existing,
           existing.fileIdentity == file.fileIdentity,
           existing.fileSize == file.size,
           existing.modifiedAt == modificationTime {
            existing.path = file.url.path
            metrics.reusedFileCount += 1
            return existing
        }

        let boundaryMatches = existing.map {
            hasMatchingParsedBoundary($0, in: file)
        } ?? false
        let canReadIncrementally = existing.map {
            $0.fileIdentity == file.fileIdentity
                && file.size > $0.fileSize
                && $0.parsedOffset <= $0.fileSize
                && modificationTime >= $0.modifiedAt
                && boundaryMatches
        } ?? false

        var entry: CachedJSONLFile
        let startOffset: UInt64
        if canReadIncrementally, let existing {
            entry = existing
            startOffset = existing.parsedOffset
            metrics.incrementalFileCount += 1
        } else {
            entry = CachedJSONLFile(
                path: file.url.path,
                fileIdentity: file.fileIdentity,
                fileSize: 0,
                modifiedAt: 0,
                parsedOffset: 0,
                parsedBoundaryFingerprint: nil,
                lastCumulativeTotalTokens: nil,
                lastTokenEventFingerprint: nil,
                sessionID: file.sessionID,
                parentSessionID: nil,
                tokenRecords: [],
                totalsByDay: [:],
                sawTokenEvents: false
            )
            startOffset = 0
            metrics.fullScanFileCount += 1
        }

        do {
            let scan = try scanJSONLFile(
                file,
                fromOffset: startOffset,
                accountScope: accountScope,
                firstDay: firstDay,
                previousCumulativeTotalTokens: entry.lastCumulativeTotalTokens,
                previousTokenEventFingerprint: entry.lastTokenEventFingerprint,
                previousSessionID: entry.sessionID,
                previousParentSessionID: entry.parentSessionID
            )
            metrics.bytesRead += scan.bytesRead

            entry.path = file.url.path
            entry.fileIdentity = file.fileIdentity
            entry.fileSize = file.size
            entry.modifiedAt = modificationTime
            entry.parsedOffset = scan.committedOffset
            entry.parsedBoundaryFingerprint = scan.parsedBoundaryFingerprint
            entry.lastCumulativeTotalTokens = scan.lastCumulativeTotalTokens
            entry.lastTokenEventFingerprint = scan.lastTokenEventFingerprint
            entry.sessionID = scan.sessionID ?? entry.sessionID ?? file.sessionID
            entry.parentSessionID = scan.parentSessionID ?? entry.parentSessionID
            entry.tokenRecords.append(contentsOf: scan.tokenRecords)
            entry.sawTokenEvents = entry.sawTokenEvents || scan.sawTokenEvents
            for (day, total) in scan.totalsByDay {
                entry.totalsByDay[day, default: 0] += total
            }
            return entry
        } catch {
            try Task.checkCancellation()
            metrics.failedFileCount += 1
            if let existing {
                return existing
            }
            return entry
        }
    }

    private func scanJSONLFile(
        _ file: JSONLFile,
        fromOffset startOffset: UInt64,
        accountScope: LocalAccountScope?,
        firstDay: Date,
        previousCumulativeTotalTokens: Int?,
        previousTokenEventFingerprint: String?,
        previousSessionID: String?,
        previousParentSessionID: String?
    ) throws -> JSONLScanResult {
        guard startOffset <= file.size else {
            throw TrendCacheError.fileChangedDuringRead
        }

        let handle = try FileHandle(forReadingFrom: file.url)
        defer {
            try? handle.close()
        }
        try handle.seek(toOffset: startOffset)

        let requestedByteCount = file.size - startOffset
        var remainingByteCount = requestedByteCount
        var bytesRead = UInt64(0)
        var buffer = Data()
        var totalsByDay: [Int: Int] = [:]
        var sawTokenEvents = false
        var lastCumulativeTotalTokens = previousCumulativeTotalTokens
        var lastTokenEventFingerprint = previousTokenEventFingerprint
        var sessionID = previousSessionID
        var parentSessionID = previousParentSessionID
        var tokenRecords: [CachedTokenRecord] = []
        let calendar = Calendar.current

        while remainingByteCount > 0 {
            try Task.checkCancellation()
            let readCount = min(streamChunkSize, Int(min(remainingByteCount, UInt64(Int.max))))
            try autoreleasepool {
                guard let chunk = try handle.read(upToCount: readCount), !chunk.isEmpty else {
                    throw TrendCacheError.fileChangedDuringRead
                }

                buffer.append(chunk)
                bytesRead += UInt64(chunk.count)
                remainingByteCount -= UInt64(chunk.count)

                var consumedThrough = buffer.startIndex
                while consumedThrough < buffer.endIndex,
                      let newline = buffer[consumedThrough...].firstIndex(of: 0x0A) {
                    let line = buffer[consumedThrough..<newline]
                    consumedThrough = buffer.index(after: newline)

                    let containsTokenCount = containsTokenCountMarker(line)
                    if !containsTokenCount,
                       line.range(of: Self.sessionMetaMarker) != nil,
                       let metadata = parseSessionMetadata(from: Data(line)) {
                        // Forked logs can replay the parent's session_meta later in
                        // the file. The first metadata record owns this JSONL.
                        sessionID = sessionID ?? metadata.sessionID
                        parentSessionID = parentSessionID ?? metadata.parentSessionID
                    }

                    guard containsTokenCount else {
                        continue
                    }

                    let lineData = Data(line)
                    guard let event = parseTokenEvent(from: lineData, sourceURL: file.url),
                          isGeneralUsageLimit(event.snapshot) else {
                        continue
                    }

                    sawTokenEvents = true
                    let tokenDelta = countedTokenDelta(
                        for: event,
                        allowInitialCumulative: startOffset == 0,
                        lastCumulativeTotalTokens: &lastCumulativeTotalTokens,
                        lastTokenEventFingerprint: &lastTokenEventFingerprint
                    )
                    guard isInCurrentLocalAccountScope(event.snapshot, scope: accountScope) else {
                        continue
                    }

                    let day = calendar.startOfDay(for: event.timestamp)
                    let dayTimestamp = Int(day.timeIntervalSince1970)
                    tokenRecords.append(
                        CachedTokenRecord(
                            dayTimestamp: dayTimestamp,
                            cumulativeTotalTokens: event.cumulativeTotalTokens,
                            reportedLastTokens: event.tokenDelta,
                            countedDelta: tokenDelta
                        )
                    )
                    if event.timestamp >= firstDay, tokenDelta > 0 {
                        totalsByDay[dayTimestamp, default: 0] += tokenDelta
                    }
                }

                if consumedThrough > buffer.startIndex {
                    buffer.removeSubrange(buffer.startIndex..<consumedThrough)
                }
            }
        }

        let currentValues = try file.url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .fileSizeKey
        ])
        let currentIdentity = Self.fileIdentity(
            currentValues.fileResourceIdentifier,
            fallbackURL: file.url
        )
        guard currentIdentity == file.fileIdentity,
              UInt64(max(0, currentValues.fileSize ?? 0)) >= file.size else {
            throw TrendCacheError.fileChangedDuringRead
        }

        let committedOffset = startOffset + bytesRead - UInt64(buffer.count)
        return JSONLScanResult(
            committedOffset: committedOffset,
            bytesRead: bytesRead,
            parsedBoundaryFingerprint: try parsedBoundaryFingerprint(
                in: file.url,
                through: committedOffset
            ),
            lastCumulativeTotalTokens: lastCumulativeTotalTokens,
            lastTokenEventFingerprint: lastTokenEventFingerprint,
            sessionID: sessionID,
            parentSessionID: parentSessionID,
            tokenRecords: tokenRecords,
            totalsByDay: totalsByDay,
            sawTokenEvents: sawTokenEvents
        )
    }

    private func copiedTokenPrefixCounts(
        in entriesByCacheKey: [String: CachedJSONLFile]
    ) -> [String: Int] {
        var entriesBySessionID: [String: CachedJSONLFile] = [:]
        for entry in entriesByCacheKey.values {
            if let sessionID = entry.sessionID {
                entriesBySessionID[sessionID] = entry
            }
        }

        var result: [String: Int] = [:]
        for (cacheKey, child) in entriesByCacheKey {
            guard let parentSessionID = child.parentSessionID,
                  let parent = entriesBySessionID[parentSessionID],
                  !child.tokenRecords.isEmpty,
                  !parent.tokenRecords.isEmpty else {
                continue
            }

            let maximumPrefixCount = min(child.tokenRecords.count, parent.tokenRecords.count)
            var prefixCount = 0
            while prefixCount < maximumPrefixCount,
                  child.tokenRecords[prefixCount].matchesCopiedState(
                      parent.tokenRecords[prefixCount]
                  ) {
                prefixCount += 1
            }

            if prefixCount > 0 {
                result[cacheKey] = prefixCount
            }
        }
        return result
    }

    private func countedTokenDelta(
        for event: ParsedTokenEvent,
        allowInitialCumulative: Bool,
        lastCumulativeTotalTokens: inout Int?,
        lastTokenEventFingerprint: inout String?
    ) -> Int {
        if lastTokenEventFingerprint == event.eventFingerprint {
            lastCumulativeTotalTokens = event.cumulativeTotalTokens ?? lastCumulativeTotalTokens
            return 0
        }

        let delta: Int
        if let cumulativeTotalTokens = event.cumulativeTotalTokens {
            if let previous = lastCumulativeTotalTokens {
                let difference = cumulativeTotalTokens.subtractingReportingOverflow(previous)
                if !difference.overflow, difference.partialValue >= 0 {
                    delta = difference.partialValue
                } else {
                    delta = max(0, event.tokenDelta)
                }
            } else if event.tokenDelta > 0 {
                delta = event.tokenDelta
            } else {
                delta = allowInitialCumulative ? max(0, cumulativeTotalTokens) : 0
            }
            lastCumulativeTotalTokens = cumulativeTotalTokens
        } else {
            delta = max(0, event.tokenDelta)
        }

        lastTokenEventFingerprint = event.eventFingerprint
        return delta
    }

    private func hasMatchingParsedBoundary(
        _ entry: CachedJSONLFile,
        in file: JSONLFile
    ) -> Bool {
        guard entry.fileIdentity == file.fileIdentity,
              entry.parsedOffset <= file.size,
              let expectedFingerprint = entry.parsedBoundaryFingerprint,
              let actualFingerprint = try? parsedBoundaryFingerprint(
                  in: file.url,
                  through: entry.parsedOffset
              ) else {
            return false
        }

        return actualFingerprint == expectedFingerprint
    }

    private func lastCompleteLineOffset(in url: URL, fileSize: UInt64) throws -> UInt64 {
        guard fileSize > 0 else {
            return 0
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        try handle.seek(toOffset: fileSize - 1)
        guard let finalByte = try handle.read(upToCount: 1),
              finalByte.count == 1 else {
            throw TrendCacheError.fileChangedDuringRead
        }
        if finalByte[finalByte.startIndex] == 0x0A {
            return fileSize
        }

        var searchEnd = fileSize - 1
        while searchEnd > 0 {
            try Task.checkCancellation()
            let readSize = min(UInt64(streamChunkSize), searchEnd)
            let readStart = searchEnd - readSize
            try handle.seek(toOffset: readStart)
            guard let chunk = try handle.read(upToCount: Int(readSize)),
                  chunk.count == Int(readSize) else {
                throw TrendCacheError.fileChangedDuringRead
            }

            if let newline = chunk.lastIndex(of: 0x0A) {
                let offsetInChunk = chunk.distance(from: chunk.startIndex, to: newline)
                return readStart + UInt64(offsetInChunk + 1)
            }
            searchEnd = readStart
        }

        return 0
    }

    private func parsedBoundaryFingerprint(in url: URL, through offset: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer {
            try? handle.close()
        }

        let currentSize = try handle.seekToEnd()
        guard currentSize >= offset else {
            throw TrendCacheError.fileChangedDuringRead
        }

        var hash = UInt64(14_695_981_039_346_656_037)
        func mix(_ byte: UInt8) {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        func mix(_ value: UInt64) {
            for shift in stride(from: 0, to: 64, by: 8) {
                mix(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
            }
        }
        func mix(rangeStart: UInt64, count: Int) throws {
            mix(rangeStart)
            mix(UInt64(count))
            guard count > 0 else { return }

            try handle.seek(toOffset: rangeStart)
            guard let data = try handle.read(upToCount: count),
                  data.count == count else {
                throw TrendCacheError.fileChangedDuringRead
            }
            for byte in data {
                mix(byte)
            }
        }

        mix(offset)
        let sampleSize = UInt64(Self.boundaryFingerprintByteCount)
        let prefixCount = Int(min(sampleSize, offset))
        try mix(rangeStart: 0, count: prefixCount)

        let suffixStart = max(UInt64(prefixCount), offset > sampleSize ? offset - sampleSize : 0)
        try mix(rangeStart: suffixStart, count: Int(offset - suffixStart))
        return String(format: "%016llx", hash)
    }

    private func containsTokenCountMarker(_ bytes: Data.SubSequence) -> Bool {
        bytes.range(of: Self.tokenCountMarker) != nil
    }

    private func parseSessionMetadata(from data: Data) -> ParsedSessionMetadata? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String: Any] else {
            return nil
        }

        let sessionID = normalizedSessionID(
            payload["id"] as? String ?? payload["session_id"] as? String
        )
        let parentSessionID = normalizedSessionID(
            payload["forked_from_id"] as? String
                ?? payload["parent_thread_id"] as? String
                ?? inferredParentSessionID(from: payload, sessionID: sessionID)
        )
        return ParsedSessionMetadata(
            sessionID: sessionID,
            parentSessionID: parentSessionID
        )
    }

    private func inferredParentSessionID(
        from payload: [String: Any],
        sessionID: String?
    ) -> String? {
        guard let owningSessionID = normalizedSessionID(payload["session_id"] as? String),
              owningSessionID != sessionID else {
            return nil
        }
        return owningSessionID
    }

    private func normalizedSessionID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value.lowercased()
    }

    private static func fileIdentity(_ identifier: Any?, fallbackURL: URL) -> String {
        if let data = identifier as? Data {
            return data.base64EncodedString()
        }
        if let identifier {
            return String(reflecting: identifier)
        }
        return fallbackURL.standardizedFileURL.path
    }

    private static func defaultTrendCacheURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory

        return baseURL
            .appendingPathComponent("CodexUsage", isDirectory: true)
            .appendingPathComponent("LocalTrendIndex-v3.json")
    }

    private func newestTokenEvent(in files: [JSONLFile]) throws -> ParsedTokenEvent? {
        for file in files {
            for line in try lines(from: file.url, mode: .tail).reversed() {
                guard line.contains("\"token_count\"") else {
                    continue
                }

                if let event = parseTokenEvent(from: Data(line.utf8), sourceURL: file.url),
                   isGeneralUsageLimit(event.snapshot) {
                    return event
                }
            }
        }

        return nil
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

    private func parseTokenEvent(from data: Data, sourceURL: URL) -> ParsedTokenEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let timestampString = root["timestamp"] as? String,
              let timestamp = DateParsers.parse(timestampString),
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any] else {
            return nil
        }

        let rateLimits = payload["rate_limits"] as? [String: Any]
        let totalTokenUsageObject = info["total_token_usage"] as? [String: Any]
        let tokenUsage = parseTokenUsage(totalTokenUsageObject)
        let lastTokenUsage = parseTokenUsage(info["last_token_usage"] as? [String: Any])
        let cumulativeTotalTokens = optionalIntValue(totalTokenUsageObject?["total_tokens"])

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
            cumulativeTotalTokens: cumulativeTotalTokens,
            eventFingerprint: [
                timestampString,
                cumulativeTotalTokens.map(String.init) ?? "nil",
                String(lastTokenUsage.totalTokens)
            ].joined(separator: "|"),
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

        // Current Codex token-count events usually omit account identity. Keep
        // structured quota events as unattributed device-local usage rather
        // than silently dropping the trend; README documents this limitation.
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

    private func dailyTrendPoints(
        from totalsByDay: [Date: Int],
        firstDay: Date
    ) -> [UsageTrendPoint] {
        guard totalsByDay.values.contains(where: { $0 > 0 }) else {
            return []
        }

        let calendar = Calendar.current
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
    var cumulativeTotalTokens: Int?
    var eventFingerprint: String
    var snapshot: CodexUsageSnapshot
}

private struct ParsedSessionMetadata {
    var sessionID: String?
    var parentSessionID: String?
}

private struct JSONLTrendResult {
    var points: [UsageTrendPoint]
    var sawTokenEvents: Bool
}

struct LocalTrendScanMetrics: Equatable, Sendable {
    var discoveredFileCount = 0
    var reusedFileCount = 0
    var baselinedFileCount = 0
    var incrementalFileCount = 0
    var fullScanFileCount = 0
    var failedFileCount = 0
    var bytesRead = UInt64(0)
}

private struct PersistedJSONLTrendCache: Codable, Equatable {
    var schemaVersion: Int
    var codexHomePath: String
    var accountIdentifiers: [String]
    var calendarIdentifier: String
    var timeZoneIdentifier: String
    var files: [String: CachedJSONLFile]

    func matches(
        schemaVersion: Int,
        codexHomePath: String,
        accountIdentifiers: [String],
        calendarIdentifier: String,
        timeZoneIdentifier: String
    ) -> Bool {
        self.schemaVersion == schemaVersion
            && self.codexHomePath == codexHomePath
            && self.accountIdentifiers == accountIdentifiers
            && self.calendarIdentifier == calendarIdentifier
            && self.timeZoneIdentifier == timeZoneIdentifier
    }
}

private struct CachedJSONLFile: Codable, Equatable {
    var path: String
    var fileIdentity: String
    var fileSize: UInt64
    var modifiedAt: TimeInterval
    var parsedOffset: UInt64
    var parsedBoundaryFingerprint: String?
    var lastCumulativeTotalTokens: Int?
    var lastTokenEventFingerprint: String?
    var sessionID: String?
    var parentSessionID: String?
    var tokenRecords: [CachedTokenRecord]
    var totalsByDay: [Int: Int]
    var sawTokenEvents: Bool

    func pruningDays(before firstDay: Date) -> CachedJSONLFile {
        var copy = self
        let firstDayTimestamp = Int(firstDay.timeIntervalSince1970)
        copy.totalsByDay = totalsByDay.filter { day, _ in
            day >= firstDayTimestamp
        }
        return copy
    }
}

private struct CachedTokenRecord: Codable, Equatable {
    var dayTimestamp: Int
    var cumulativeTotalTokens: Int?
    var reportedLastTokens: Int
    var countedDelta: Int

    func matchesCopiedState(_ other: CachedTokenRecord) -> Bool {
        guard let cumulativeTotalTokens,
              let otherCumulativeTotalTokens = other.cumulativeTotalTokens else {
            return false
        }
        return cumulativeTotalTokens == otherCumulativeTotalTokens
            && reportedLastTokens == other.reportedLastTokens
    }
}

private struct JSONLScanResult {
    var committedOffset: UInt64
    var bytesRead: UInt64
    var parsedBoundaryFingerprint: String
    var lastCumulativeTotalTokens: Int?
    var lastTokenEventFingerprint: String?
    var sessionID: String?
    var parentSessionID: String?
    var tokenRecords: [CachedTokenRecord]
    var totalsByDay: [Int: Int]
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
    var cards: [ResetCard] {
        credits.map {
            ResetCard(
                status: $0.status,
                expiresAt: $0.expiresAt
            )
        }
    }

    private var credits: [Credit]

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

        credits = (try? container.decodeIfPresent([Credit].self, forKey: .credits)) ?? []
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
    var size: UInt64
    var fileIdentity: String

    var cacheKey: String {
        if let sessionID {
            return "session:\(sessionID)"
        }

        return "file:\(fileIdentity)"
    }

    var sessionID: String? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard stem.count >= 36 else { return nil }
        let candidate = String(stem.suffix(36))
        return UUID(uuidString: candidate)?.uuidString.lowercased()
    }
}

private enum JSONLReadMode {
    case tail
}

private enum TrendCacheError: Error {
    case fileChangedDuringRead
}

private enum DateParsers {
    private static let fractionalSeconds = Date.ISO8601FormatStyle(
        includingFractionalSeconds: true
    )
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    static func parse(_ value: String) -> Date? {
        (try? fractionalSeconds.parse(value))
            ?? (try? wholeSeconds.parse(value))
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
