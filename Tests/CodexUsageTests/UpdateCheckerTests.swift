import Foundation
import Testing
@testable import CodexUsage

@Suite("GitHub app releases")
struct UpdateCheckerTests {
    @Test("The GitHub release endpoint is the canonical update source")
    func usesGitHubReleaseEndpoint() {
        #expect(
            UpdateConfiguration.latestReleaseAPIURL.absoluteString
                == "https://api.github.com/repos/cixiangtao/codex-usage/releases/latest"
        )
    }

    @Test("A CodexUsage zip is selected from GitHub release assets")
    func selectsApplicationArchive() throws {
        let release = try JSONDecoder().decode(
            GitHubAppRelease.self,
            from: Data(
                """
                {
                  "tag_name": "v1.2.3",
                  "name": "CodexUsage v1.2.3",
                  "html_url": "https://github.com/cixiangtao/codex-usage/releases/tag/v1.2.3",
                  "assets": [
                    {
                      "name": "SHA256SUMS.txt",
                      "browser_download_url": "https://example.com/SHA256SUMS.txt"
                    },
                    {
                      "name": "CodexUsage-v1.2.3.zip",
                      "browser_download_url": "https://example.com/CodexUsage-v1.2.3.zip"
                    }
                  ]
                }
                """.utf8
            )
        )

        #expect(release.normalizedVersion == "1.2.3")
        #expect(release.displayName == "CodexUsage v1.2.3")
        #expect(release.preferredDownloadURL?.absoluteString == "https://example.com/CodexUsage-v1.2.3.zip")
    }

    @Test("A release without an application archive is not installable")
    func rejectsUnrelatedAssets() throws {
        let release = try JSONDecoder().decode(
            GitHubAppRelease.self,
            from: Data(
                """
                {
                  "tag_name": "v1.2.3",
                  "name": null,
                  "html_url": "https://github.com/cixiangtao/codex-usage/releases/tag/v1.2.3",
                  "assets": [
                    {
                      "name": "SHA256SUMS.txt",
                      "browser_download_url": "https://example.com/SHA256SUMS.txt"
                    }
                  ]
                }
                """.utf8
            )
        )

        #expect(release.displayName == "v1.2.3")
        #expect(release.preferredDownloadURL == nil)
    }
}
