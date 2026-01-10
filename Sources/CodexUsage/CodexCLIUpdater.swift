import Darwin
import Foundation

struct CodexCLIUpdateCheckResult: Equatable, Sendable {
    var executablePath: String
    var currentVersion: String
    var latestVersion: String

    var isUpdateAvailable: Bool {
        guard let current = SemanticVersion(currentVersion),
              let latest = SemanticVersion(latestVersion) else {
            return false
        }

        return latest > current
    }
}

enum CodexCLIUpdateState: Equatable {
    case idle
    case checking
    case current(String)
    case updateAvailable(CodexCLIUpdateCheckResult)
    case deferred(CodexCLIUpdateCheckResult)
    case updating(CodexCLIUpdateCheckResult)
    case updated(String)
    case failed(currentVersion: String?, message: String)

    var blocksDetection: Bool {
        switch self {
        case .checking, .updateAvailable, .updating:
            true
        case .idle, .current, .deferred, .updated, .failed:
            false
        }
    }

    var pendingUpdate: CodexCLIUpdateCheckResult? {
        guard case .updateAvailable(let result) = self else { return nil }
        return result
    }

    var currentVersion: String? {
        switch self {
        case .current(let version), .updated(let version):
            version
        case .updateAvailable(let result), .deferred(let result), .updating(let result):
            result.currentVersion
        case .failed(let currentVersion, _):
            currentVersion
        case .idle, .checking:
            nil
        }
    }
}

struct CodexCLIUpdater: Sendable {
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/openai/codex/releases/latest")!

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func checkForUpdate(executablePath: String) async throws -> CodexCLIUpdateCheckResult {
        async let installedVersion = installedVersion(at: executablePath)
        async let latestRelease = fetchLatestRelease()
        let (currentVersion, release) = try await (installedVersion, latestRelease)

        return CodexCLIUpdateCheckResult(
            executablePath: executablePath,
            currentVersion: currentVersion,
            latestVersion: release.version
        )
    }

    func installedVersion(at executablePath: String) async throws -> String {
        try await Task.detached(priority: .utility) {
            let process = Process()
            let output = Pipe()
            let error = Pipe()

            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["--version"]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = error

            try process.run()
            guard process.waitUntilExit(timeout: 5) else {
                throw CodexCLIUpdateError.commandTimedOut("读取 Codex CLI 版本")
            }

            let outputData = output.fileHandleForReading.readDataToEndOfFile()
            let errorData = error.fileHandleForReading.readDataToEndOfFile()
            let outputText = String(data: outputData, encoding: .utf8) ?? ""
            let errorText = String(data: errorData, encoding: .utf8) ?? ""

            guard process.terminationStatus == 0 else {
                throw CodexCLIUpdateError.versionCommandFailed(
                    Self.lastUsefulLine(in: errorText) ?? "退出码 \(process.terminationStatus)"
                )
            }

            guard let version = outputText
                .split(whereSeparator: \.isWhitespace)
                .last
                .map(String.init),
                Self.isStableVersion(version) else {
                throw CodexCLIUpdateError.invalidInstalledVersion(outputText)
            }

            return version
        }.value
    }

    func update(
        executablePath: String,
        codexHomePath: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let temporaryDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("CodexCLIUpdate-\(UUID().uuidString)", isDirectory: true)
            let logURL = temporaryDirectory.appendingPathComponent("update.log")

            try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            defer {
                try? fileManager.removeItem(at: temporaryDirectory)
            }

            guard fileManager.createFile(atPath: logURL.path, contents: nil) else {
                throw CodexCLIUpdateError.cannotCreateUpdateLog
            }

            let logHandle = try FileHandle(forWritingTo: logURL)
            defer {
                try? logHandle.close()
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["update"]
            process.currentDirectoryURL = fileManager.temporaryDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = logHandle
            process.standardError = logHandle

            var environment = ProcessInfo.processInfo.environment
            environment["CODEX_HOME"] = codexHomePath
            environment["CODEX_NON_INTERACTIVE"] = "1"
            process.environment = environment

            try process.run()
            guard process.waitUntilExit(timeout: 180) else {
                throw CodexCLIUpdateError.commandTimedOut("更新 Codex CLI")
            }
            try? logHandle.synchronize()

            guard process.terminationStatus == 0 else {
                let logData = (try? Data(contentsOf: logURL)) ?? Data()
                let logText = String(data: logData, encoding: .utf8) ?? ""
                throw CodexCLIUpdateError.updateFailed(
                    Self.lastUsefulLine(in: logText) ?? "退出码 \(process.terminationStatus)"
                )
            }
        }.value
    }

    private func fetchLatestRelease() async throws -> LatestRelease {
        var request = URLRequest(url: Self.latestReleaseURL)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("CodexUsage", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CodexCLIUpdateError.invalidReleaseResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw CodexCLIUpdateError.releaseHTTPStatus(httpResponse.statusCode)
        }

        guard let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw CodexCLIUpdateError.invalidReleaseResponse
        }
        guard !release.draft, !release.prerelease,
              release.tagName.hasPrefix("rust-v") else {
            throw CodexCLIUpdateError.invalidReleaseTag(release.tagName)
        }

        let version = String(release.tagName.dropFirst("rust-v".count))
        guard Self.isStableVersion(version) else {
            throw CodexCLIUpdateError.invalidReleaseTag(release.tagName)
        }

        return LatestRelease(version: version)
    }

    private static func isStableVersion(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy(\.isNumber)
        }
    }

    private static func lastUsefulLine(in output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .last(where: { !$0.isEmpty })
    }
}

extension Process {
    func waitUntilExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        guard isRunning else {
            waitUntilExit()
            return true
        }

        terminateAndWait()
        return false
    }

    func terminateAndWait(gracePeriod: TimeInterval = 1) {
        if isRunning {
            terminate()
        }

        let terminationDeadline = Date().addingTimeInterval(gracePeriod)
        while isRunning, Date() < terminationDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if isRunning {
            kill(processIdentifier, SIGKILL)
        }
        waitUntilExit()
    }
}

enum CodexCLIUpdateError: LocalizedError, Equatable {
    case invalidReleaseResponse
    case releaseHTTPStatus(Int)
    case invalidReleaseTag(String)
    case invalidInstalledVersion(String)
    case versionCommandFailed(String)
    case cannotCreateUpdateLog
    case updateFailed(String)
    case commandTimedOut(String)
    case verificationFailed(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case .invalidReleaseResponse:
            "无法读取 Codex CLI 最新版本响应。"
        case .releaseHTTPStatus(let status):
            if status == 403 || status == 429 {
                "Codex CLI 更新检测请求受限，请稍后重试。"
            } else {
                "Codex CLI 更新检测失败，状态码 \(status)。"
            }
        case .invalidReleaseTag(let tag):
            "无法识别 Codex CLI 最新版本：\(tag)。"
        case .invalidInstalledVersion:
            "无法识别当前 Codex CLI 版本。"
        case .versionCommandFailed(let detail):
            "读取 Codex CLI 版本失败：\(detail)"
        case .cannotCreateUpdateLog:
            "无法创建 Codex CLI 更新日志。"
        case .updateFailed(let detail):
            "Codex CLI 更新失败：\(detail)"
        case .commandTimedOut(let operation):
            "\(operation)超时，请稍后重试。"
        case let .verificationFailed(expected, actual):
            "Codex CLI 更新校验失败：期望至少 \(expected)，当前仍为 \(actual)。"
        }
    }
}

private struct LatestRelease: Sendable {
    var version: String
}

private struct GitHubRelease: Decodable, Sendable {
    var tagName: String
    var draft: Bool
    var prerelease: Bool

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
    }
}
