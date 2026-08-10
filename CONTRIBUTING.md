# Contributing

English | [简体中文](CONTRIBUTING.zh-CN.md)

Thank you for improving CodexUsage. Changes should preserve its identity as a native macOS menu-bar app and provide a clear difference in design, runtime behavior, data sourcing, system integration, or user workflow from similar projects such as `codex-bar`.

## Reporting issues

- Include the app version, macOS version, and a minimal reproduction for bugs.
- Explain the user problem and differentiated value for feature requests.
- Report security issues privately through [Security](SECURITY.md).
- Remove access tokens, account data, and sensitive local paths from logs and screenshots.

## Local development

Use macOS 14 or later, Swift 6, and Bun 1.3.14.

```sh
bun install --frozen-lockfile
swift build
swift test
bun run typecheck
```

For packaging, resource, or release-script changes, also run `bun run package:app`.

## Pull requests

Keep changes focused, update tests and documentation with behavior, and describe the problem, approach, user-visible impact, and verification. Do not commit build output, credentials, personal data, or machine-specific configuration. Version changes, tags, and Releases belong to the Actions-owned release flow.

By submitting a pull request, you agree to license the contribution under the repository's [MIT License](LICENSE).
