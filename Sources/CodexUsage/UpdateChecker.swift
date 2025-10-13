import Foundation

struct UpdateCheckResult: Equatable, Sendable {
    var currentVersion: String
    var latestVersion: String
    var releaseName: String
    var releasePageURL: URL
    var downloadURL: URL?
    var checkedAt: Date
    var isUpdateAvailable: Bool
}

struct UpdateChecker: Sendable {
    private let session: URLSession
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func checkForUpdates() async throws -> UpdateCheckResult {
        let request = URLRequest(url: UpdateConfiguration.latestReleaseAPIURL)
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            throw UpdateCheckError.httpStatus(httpResponse.statusCode)
        }

        let release = try decoder.decode(GitLabRelease.self, from: data)
        let currentVersion = Self.currentVersion
        let latestVersion = release.normalizedVersion
        let releasePageURL = UpdateConfiguration.releasePageURL
        let downloadURL = release.preferredDownloadURL

        return UpdateCheckResult(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseName: release.displayName,
            releasePageURL: releasePageURL,
            downloadURL: downloadURL,
            checkedAt: Date(),
            isUpdateAvailable: Self.isVersion(latestVersion, newerThan: currentVersion)
        )
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        guard let left = SemanticVersion(lhs),
              let right = SemanticVersion(rhs) else {
            return lhs.compare(rhs, options: .numeric) == .orderedDescending
        }

        return left > right
    }
}

enum UpdateCheckError: LocalizedError, Equatable {
    case invalidResponse
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "无法读取 GitLab 更新响应。"
        case .httpStatus(let status):
            if status == 401 || status == 403 || status == 404 {
                "无法访问 GitLab Release，请确认仓库 Release API 可匿名读取。"
            } else {
                "GitLab 更新检测失败，状态码 \(status)。"
            }
        }
    }
}

private enum UpdateConfiguration {
    static let gitLabHost = "gitlab-ee.zhenguanyu.com"
    static let projectPath = "cixiangtao/codex-usage"

    static var latestReleaseAPIURL: URL {
        URL(string: "https://\(gitLabHost)/api/v4/projects/\(encodedProjectPath)/releases/permalink/latest")!
    }

    static var releasePageURL: URL {
        URL(string: "https://\(gitLabHost)/\(projectPath)/-/releases")!
    }

    private static var encodedProjectPath: String {
        projectPath.replacingOccurrences(of: "/", with: "%2F")
    }
}

private struct GitLabRelease: Decodable, Equatable, Sendable {
    var tagName: String
    var name: String?
    var assets: GitLabReleaseAssets?

    var normalizedVersion: String {
        tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
    }

    var displayName: String {
        name?.isEmpty == false ? name! : tagName
    }

    var preferredDownloadURL: URL? {
        assets?.links
            .first { link in
                let lowercasedName = link.name.lowercased()
                return lowercasedName.contains("codexusage") && lowercasedName.hasSuffix(".zip")
            }?
            .downloadURL
        ?? assets?.links.first?.downloadURL
    }

    private enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case assets
    }
}

private struct GitLabReleaseAssets: Decodable, Equatable, Sendable {
    var links: [GitLabReleaseAssetLink]
}

private struct GitLabReleaseAssetLink: Decodable, Equatable, Sendable {
    var name: String
    var url: URL
    var directAssetURL: URL?

    var downloadURL: URL {
        directAssetURL ?? url
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case url
        case directAssetURL = "direct_asset_url"
    }
}

private struct SemanticVersion: Comparable, Equatable {
    private var parts: [Int]

    init?(_ version: String) {
        let normalized = version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            .split(separator: "-", maxSplits: 1)
            .first?
            .split(separator: "+", maxSplits: 1)
            .first

        guard let normalized else { return nil }

        let parts = normalized.split(separator: ".").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }

        self.parts = parts
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)

        for index in 0..<count {
            let left = lhs.parts.indices.contains(index) ? lhs.parts[index] : 0
            let right = rhs.parts.indices.contains(index) ? rhs.parts[index] : 0

            if left != right {
                return left < right
            }
        }

        return false
    }
}
