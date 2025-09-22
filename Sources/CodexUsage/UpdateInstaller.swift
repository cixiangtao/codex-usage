import Foundation

struct UpdateInstaller: Sendable {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func prepareInstall(from url: URL) async throws -> UpdateInstallPlan {
        let fileManager = FileManager.default
        let currentAppURL = try Self.currentApplicationURL()
        let stagingURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodexUsageUpdate-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = stagingURL.appendingPathComponent("CodexUsageUpdate.zip")
        let extractURL = stagingURL.appendingPathComponent("Extracted", isDirectory: true)

        try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: extractURL, withIntermediateDirectories: true)

        do {
            let (downloadedURL, response) = try await session.download(for: URLRequest(url: url))
            guard let httpResponse = response as? HTTPURLResponse else {
                throw UpdateInstallError.invalidDownloadResponse
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                throw UpdateInstallError.downloadStatus(httpResponse.statusCode)
            }

            try fileManager.moveItem(at: downloadedURL, to: archiveURL)
            try await Self.run("/usr/bin/ditto", arguments: ["-x", "-k", archiveURL.path, extractURL.path])

            let newAppURL = try findApplication(in: extractURL, matching: currentAppURL)
            let scriptURL = try writeRelaunchScript(in: stagingURL)

            return UpdateInstallPlan(
                currentAppURL: currentAppURL,
                newAppURL: newAppURL,
                scriptURL: scriptURL,
                stagingURL: stagingURL
            )
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }
    }

    func installAndRelaunch(_ plan: UpdateInstallPlan) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            plan.scriptURL.path,
            plan.currentAppURL.path,
            plan.newAppURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            plan.stagingURL.path
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    static var canInstallCurrentApplication: Bool {
        (try? currentApplicationURL()) != nil
    }

    private static func currentApplicationURL() throws -> URL {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            throw UpdateInstallError.notApplicationBundle
        }

        return bundleURL
    }

    private func findApplication(in directoryURL: URL, matching currentAppURL: URL) throws -> URL {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw UpdateInstallError.missingApplicationBundle
        }

        let currentBundleIdentifier = Bundle(url: currentAppURL)?.bundleIdentifier
        for case let appURL as URL in enumerator where appURL.pathExtension == "app" {
            guard let bundle = Bundle(url: appURL) else { continue }
            if let currentBundleIdentifier,
               bundle.bundleIdentifier != currentBundleIdentifier {
                continue
            }

            return appURL
        }

        throw UpdateInstallError.missingApplicationBundle
    }

    private func writeRelaunchScript(in directoryURL: URL) throws -> URL {
        let fileManager = FileManager.default
        let scriptURL = directoryURL.appendingPathComponent("install-and-relaunch.zsh")
        let script = """
        #!/bin/zsh
        set -euo pipefail

        current_app="$1"
        new_app="$2"
        app_pid="$3"
        staging_dir="$4"
        backup_app="${current_app}.backup.$(date +%s)"

        for _ in {1..100}; do
          if ! kill -0 "$app_pid" 2>/dev/null; then
            break
          fi
          sleep 0.2
        done

        rm -rf "$backup_app"
        if [ -e "$current_app" ]; then
          mv "$current_app" "$backup_app"
        fi

        if /usr/bin/ditto "$new_app" "$current_app"; then
          /usr/bin/xattr -dr com.apple.quarantine "$current_app" 2>/dev/null || true
          rm -rf "$backup_app"
          /usr/bin/open "$current_app"
          sleep 2
          rm -rf "$staging_dir"
        else
          rm -rf "$current_app"
          if [ -e "$backup_app" ]; then
            mv "$backup_app" "$current_app"
          fi
          exit 1
        fi
        """

        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private static func run(_ executablePath: String, arguments: [String]) async throws {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw UpdateInstallError.helperFailed(executablePath, Int(process.terminationStatus))
            }
        }.value
    }
}

struct UpdateInstallPlan: Sendable {
    var currentAppURL: URL
    var newAppURL: URL
    var scriptURL: URL
    var stagingURL: URL
}

enum UpdateInstallError: LocalizedError, Equatable {
    case notApplicationBundle
    case missingDownloadURL
    case invalidDownloadResponse
    case downloadStatus(Int)
    case missingApplicationBundle
    case helperFailed(String, Int)

    var errorDescription: String? {
        switch self {
        case .notApplicationBundle:
            "当前不是 .app 运行环境，无法自动安装。请使用 release 版应用更新。"
        case .missingDownloadURL:
            "最新 Release 没有可自动安装的 zip 包。"
        case .invalidDownloadResponse:
            "无法读取更新包下载响应。"
        case let .downloadStatus(status):
            "更新包下载失败，状态码 \(status)。"
        case .missingApplicationBundle:
            "更新包中没有找到可安装的 CodexUsage.app。"
        case let .helperFailed(path, code):
            "\(URL(fileURLWithPath: path).lastPathComponent) 执行失败，退出码 \(code)。"
        }
    }
}
