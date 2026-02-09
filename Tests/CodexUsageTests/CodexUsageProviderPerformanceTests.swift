import Foundation
import Testing
@testable import CodexUsage

@Suite("Codex usage provider performance", .serialized)
struct CodexUsageProviderPerformanceTests {
    @Test("Unchanged files are reused and appended bytes are read once")
    func incrementallyIndexesJSONLFiles() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let firstEvent = fixture.tokenEvent(timestamp: "2026-07-28T01:00:00.000Z", tokenDelta: 120)
        try fixture.write(firstEvent, to: fixture.sessionFile)

        let provider = CodexUsageProvider(
            trendCacheURL: fixture.cacheURL,
            streamChunkSize: 4_096
        )
        let referenceDate = try #require(DateParsersForTests.parse("2026-07-28T12:00:00.000Z"))

        let firstPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        let firstMetrics = await provider.lastTrendScanMetrics()
        #expect(fixture.total(on: referenceDate, in: firstPoints) == 120)
        #expect(firstMetrics.fullScanFileCount == 1)
        #expect(firstMetrics.bytesRead == UInt64(firstEvent.utf8.count))

        let cachedPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        let cachedMetrics = await provider.lastTrendScanMetrics()
        #expect(cachedPoints == firstPoints)
        #expect(cachedMetrics.bytesRead == 0)
        #expect(cachedMetrics.reusedFileCount == 1)

        let appendedEvent = fixture.tokenEvent(
            timestamp: "2026-07-28T02:00:00.000Z",
            tokenDelta: 30,
            cumulativeTotal: 150
        )
        try fixture.append(appendedEvent, to: fixture.sessionFile)

        let appendedPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        let appendedMetrics = await provider.lastTrendScanMetrics()
        #expect(fixture.total(on: referenceDate, in: appendedPoints) == 150)
        #expect(appendedMetrics.incrementalFileCount == 1)
        #expect(appendedMetrics.bytesRead == UInt64(appendedEvent.utf8.count))

        let restartedProvider = CodexUsageProvider(
            trendCacheURL: fixture.cacheURL,
            streamChunkSize: 4_096
        )
        let restartedPoints = try await restartedProvider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        let restartedMetrics = await restartedProvider.lastTrendScanMetrics()
        #expect(restartedPoints == appendedPoints)
        #expect(restartedMetrics.bytesRead == 0)
        #expect(restartedMetrics.reusedFileCount == 1)
    }

    @Test("Incomplete trailing lines are committed only after their newline arrives")
    func preservesIncompleteLineOffset() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let firstEvent = fixture.tokenEvent(timestamp: "2026-07-28T01:00:00.000Z", tokenDelta: 10)
        let secondEvent = fixture.tokenEvent(
            timestamp: "2026-07-28T02:00:00.000Z",
            tokenDelta: 20,
            cumulativeTotal: 30
        )
        let splitIndex = secondEvent.index(
            secondEvent.startIndex,
            offsetBy: secondEvent.count / 2
        )
        try fixture.write(
            firstEvent + secondEvent[..<splitIndex],
            to: fixture.sessionFile
        )

        let provider = CodexUsageProvider(
            trendCacheURL: fixture.cacheURL,
            streamChunkSize: 4_096
        )
        let referenceDate = try #require(DateParsersForTests.parse("2026-07-28T12:00:00.000Z"))

        let partialPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        #expect(fixture.total(on: referenceDate, in: partialPoints) == 10)

        try fixture.append(String(secondEvent[splitIndex...]), to: fixture.sessionFile)
        let completedPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        #expect(fixture.total(on: referenceDate, in: completedPoints) == 30)
    }

    @Test("Truncating and regrowing the same file rebuilds its contribution")
    func rebuildsTruncatedAndRegrownFileWithoutDoubleCounting() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let originalContents =
            fixture.tokenEvent(timestamp: "2026-07-28T01:00:00.000Z", tokenDelta: 100)
            + fixture.tokenEvent(
                timestamp: "2026-07-28T02:00:00.000Z",
                tokenDelta: 50,
                cumulativeTotal: 150
            )
        try fixture.write(originalContents, to: fixture.sessionFile)

        let provider = CodexUsageProvider(trendCacheURL: fixture.cacheURL)
        let referenceDate = try #require(DateParsersForTests.parse("2026-07-28T12:00:00.000Z"))
        _ = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )

        let replacementContents =
            fixture.tokenEvent(timestamp: "2026-07-28T03:00:00.000Z", tokenDelta: 7)
            + fixture.paddingLine(minimumByteCount: originalContents.utf8.count)
        try fixture.rewriteInPlace(
            replacementContents,
            at: fixture.sessionFile
        )
        let rebuiltPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        let rebuiltMetrics = await provider.lastTrendScanMetrics()

        #expect(fixture.total(on: referenceDate, in: rebuiltPoints) == 7)
        #expect(rebuiltMetrics.fullScanFileCount == 1)
    }

    @Test("Cumulative token events are counted once across appends and restarts")
    func deduplicatesCumulativeTokenEvents() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let firstEvent = fixture.tokenEvent(
            timestamp: "2026-07-28T01:00:00.000Z",
            tokenDelta: 100,
            cumulativeTotal: 100
        )
        try fixture.write(firstEvent + firstEvent, to: fixture.sessionFile)

        let provider = CodexUsageProvider(trendCacheURL: fixture.cacheURL)
        let referenceDate = try #require(DateParsersForTests.parse("2026-07-28T12:00:00.000Z"))
        let initialPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        #expect(fixture.total(on: referenceDate, in: initialPoints) == 100)

        let appendedEvent = fixture.tokenEvent(
            timestamp: "2026-07-28T02:00:00.000Z",
            tokenDelta: 25,
            cumulativeTotal: 125
        )
        try fixture.append(appendedEvent + appendedEvent, to: fixture.sessionFile)
        let appendedPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        #expect(fixture.total(on: referenceDate, in: appendedPoints) == 125)

        let restartedProvider = CodexUsageProvider(trendCacheURL: fixture.cacheURL)
        let restartedPoints = try await restartedProvider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        let restartedMetrics = await restartedProvider.lastTrendScanMetrics()
        #expect(fixture.total(on: referenceDate, in: restartedPoints) == 125)
        #expect(restartedMetrics.reusedFileCount == 1)
        #expect(restartedMetrics.bytesRead == 0)
    }

    @Test("An old file keeps an incomplete trailing record recoverable")
    func oldFileBaselinePreservesIncompleteTrailingRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        let event = fixture.tokenEvent(
            timestamp: "2026-07-28T01:00:00.000Z",
            tokenDelta: 40
        )
        let splitIndex = event.index(event.startIndex, offsetBy: event.count / 2)
        try fixture.write(event[..<splitIndex], to: fixture.sessionFile)

        let referenceDate = try #require(DateParsersForTests.parse("2026-07-28T12:00:00.000Z"))
        let oldDate = try #require(
            Calendar.current.date(byAdding: .day, value: -40, to: referenceDate)
        )
        try fixture.setModificationDate(oldDate, for: fixture.sessionFile)

        let provider = CodexUsageProvider(trendCacheURL: fixture.cacheURL)
        let baselinedPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        #expect(baselinedPoints.isEmpty)

        try fixture.append(String(event[splitIndex...]), to: fixture.sessionFile)
        let completedPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        #expect(fixture.total(on: referenceDate, in: completedPoints) == 40)
    }

    @Test("Unrelated files with the same basename are both indexed")
    func doesNotDeduplicateUnrelatedBasenameCollisions() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write(
            fixture.tokenEvent(timestamp: "2026-07-28T01:00:00.000Z", tokenDelta: 10),
            to: fixture.sessionFile
        )
        try fixture.write(
            fixture.tokenEvent(timestamp: "2026-07-28T02:00:00.000Z", tokenDelta: 20),
            to: fixture.archivedSessionFile
        )

        let provider = CodexUsageProvider(trendCacheURL: fixture.cacheURL)
        let referenceDate = try #require(DateParsersForTests.parse("2026-07-28T12:00:00.000Z"))
        let points = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        #expect(fixture.total(on: referenceDate, in: points) == 30)
    }

    @Test("Moving a session file reuses its cached contribution")
    func reusesMovedSessionFile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write(
            fixture.tokenEvent(timestamp: "2026-07-28T01:00:00.000Z", tokenDelta: 55),
            to: fixture.sessionFile
        )
        let provider = CodexUsageProvider(trendCacheURL: fixture.cacheURL)
        let referenceDate = try #require(DateParsersForTests.parse("2026-07-28T12:00:00.000Z"))
        _ = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )

        try FileManager.default.moveItem(
            at: fixture.sessionFile,
            to: fixture.archivedSessionFile
        )
        let movedPoints = try await provider.fetchTrendPoints(
            codexHomePath: fixture.root.path,
            relativeTo: referenceDate
        )
        let movedMetrics = await provider.lastTrendScanMetrics()
        #expect(fixture.total(on: referenceDate, in: movedPoints) == 55)
        #expect(movedMetrics.reusedFileCount == 1)
        #expect(movedMetrics.bytesRead == 0)
    }

    @Test("Cancelling while reset cards load cancels the whole snapshot")
    func propagatesResetCardCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write(
            #"{"tokens":{"access_token":"test-token","account_id":"test-account"}}"#,
            to: fixture.root.appendingPathComponent("auth.json")
        )
        MockURLProtocol.requestHandler = { request in
            let body: String
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                Thread.sleep(forTimeInterval: 0.5)
                body = #"{"available_count":0,"credits":[]}"#
            } else {
                body = """
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 12,
                      "limit_window_seconds": 18000
                    }
                  }
                }
                """
            }

            let response = try #require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let provider = CodexUsageProvider(
            session: session,
            trendCacheURL: fixture.cacheURL
        )
        let task = Task {
            try await provider.fetchLatestSnapshot(codexHomePath: fixture.root.path)
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected the cancelled snapshot task to throw CancellationError.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, got \(error).")
        }
    }

    @Test("A successful remote snapshot does not merge local token logs")
    func prefersRemoteSnapshotWithoutLocalScanMerge() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }

        try fixture.write(
            fixture.tokenEvent(timestamp: "2026-07-28T01:00:00.000Z", tokenDelta: 999),
            to: fixture.sessionFile
        )
        try fixture.write(
            """
            {"tokens":{"access_token":"test-token","account_id":"test-account"}}
            """,
            to: fixture.root.appendingPathComponent("auth.json")
        )

        MockURLProtocol.requestHandler = { request in
            let body: String
            if request.url?.path.contains("rate-limit-reset-credits") == true {
                body = #"{"available_count":0,"credits":[]}"#
            } else {
                body = """
                {
                  "email": "test@example.com",
                  "plan_type": "pro",
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 12,
                      "limit_window_seconds": 18000
                    }
                  }
                }
                """
            }

            let response = try #require(
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )
            )
            return (response, Data(body.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let provider = CodexUsageProvider(
            session: session,
            trendCacheURL: fixture.cacheURL
        )
        let snapshot = try await provider.fetchLatestSnapshot(codexHomePath: fixture.root.path)

        #expect(snapshot.source == "OpenAI OAuth API")
        #expect(snapshot.accountIdentifier == "test@example.com")
        #expect(snapshot.tokenUsage == .empty)
        #expect(snapshot.primary?.usedPercent == 12)
    }

}

private struct Fixture {
    let root: URL
    let sessionFile: URL
    let archivedSessionFile: URL
    let cacheURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageProviderTests-\(UUID().uuidString)", isDirectory: true)
        let sessionsURL = root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("2026/07/28", isDirectory: true)
        sessionFile = sessionsURL.appendingPathComponent("rollout-test-session.jsonl")
        let archivedSessionsURL = root
            .appendingPathComponent("archived_sessions", isDirectory: true)
            .appendingPathComponent("2026/07/28", isDirectory: true)
        archivedSessionFile = archivedSessionsURL.appendingPathComponent("rollout-test-session.jsonl")
        cacheURL = root
            .appendingPathComponent("ApplicationSupport", isDirectory: true)
            .appendingPathComponent("LocalTrendIndex.json")
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: archivedSessionsURL,
            withIntermediateDirectories: true
        )
    }

    func tokenEvent(
        timestamp: String,
        tokenDelta: Int,
        cumulativeTotal: Int? = nil
    ) -> String {
        let cumulativeTotal = cumulativeTotal ?? tokenDelta
        return """
        {"timestamp":"\(timestamp)","payload":{"type":"token_count","info":{"total_token_usage":{"total_tokens":\(cumulativeTotal)},"last_token_usage":{"total_tokens":\(tokenDelta)}},"rate_limits":{"limit_id":"codex","plan_type":"pro","primary":{"used_percent":20,"window_minutes":300}}}}

        """
    }

    func paddingLine(minimumByteCount: Int) -> String {
        let padding = String(repeating: "x", count: minimumByteCount)
        return #"{"payload":{"type":"padding","value":"\#(padding)"}}"# + "\n"
    }

    func write<S: StringProtocol>(_ contents: S, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    func rewriteInPlace(_ contents: String, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(contents.utf8))
        try handle.synchronize()
    }

    func append(_ contents: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
        try handle.synchronize()
    }

    func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    func total(on date: Date, in points: [UsageTrendPoint]) -> Int? {
        points.first { Calendar.current.isDate($0.capturedAt, inSameDayAs: date) }?.totalTokens
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requestHandler:
        ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private enum DateParsersForTests {
    static func parse(_ value: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
    }
}
