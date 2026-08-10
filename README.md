# CodexUsage

English | [简体中文](README.zh-CN.md)

A native macOS menu-bar app for Codex usage snapshots, reset times, notifications, local trend history, and a shared WidgetKit state.

## What it does

- Shows the selected `5h` and `7d` remaining-usage windows in the menu bar.
- Expands into a detailed usage panel with reset timing and notification controls.
- Reads server-side usage through the OAuth credential already managed by Codex CLI.
- Falls back to structured `rate_limits` and token-count events in local Codex session logs.
- Detects low allowance, recovery, expiring reset cards, and refresh failures.
- Stores recent local intelligence snapshots and a shared snapshot for WidgetKit.
- Includes a Widget Extension source skeleton under `WidgetExtension/`.

## Preview

<p align="center">
  <img src="docs/images/overview.png" alt="CodexUsage usage panel" width="360">
</p>

<p align="center"><sub>The preview uses sanitized demo data and irreversibly masked account details.</sub></p>

| Menu-bar display | Animated icon |
| --- | --- |
| <img src="docs/images/status-bar-settings.png" alt="Menu-bar display settings"> | <img src="docs/images/icon-settings.png" alt="Animated icon settings"> |

## Install

Download the latest `CodexUsage-vX.Y.Z.dmg` from [GitHub Releases](https://github.com/cixiangtao/codex-usage/releases/latest), open it, and drag `CodexUsage.app` to Applications. Each release also includes the ZIP used by the in-app updater and `SHA256SUMS.txt`.

The current public builds use ad-hoc signing. macOS may quarantine browser-downloaded artifacts and warn that Apple cannot verify the app. For a local installation:

```sh
xattr -dr com.apple.quarantine /Applications/CodexUsage.app
open /Applications/CodexUsage.app
```

## Data boundaries

CodexUsage first reads the Codex CLI OAuth access token from `~/.codex/auth.json` and requests the Codex usage endpoint on `chatgpt.com`. It does not read passwords, upload local logs, or copy the token into its own settings.

If the credential or endpoint is unavailable, the app reads structured usage snapshots from `~/.codex/sessions/**/*.jsonl` and `~/.codex/archived_sessions/**/*.jsonl`. Daily trends aggregate local token-count events; events without account identifiers are necessarily treated as unassigned usage from this Mac, so history can include another locally used account. If those events are unavailable, the final fallback is the thread-level `tokens_used` total in `~/.codex/state_5.sqlite`.

Remote usage polling and local trend indexing are independent. Trend data is refreshed on demand and cached for ten minutes. Incremental state lives at `~/Library/Application Support/CodexUsage/LocalTrendIndex-v2.json`; deleting it triggers a rebuild.

## Development

The project is a Swift Package and can run without a generated Xcode project.

```sh
bun install --frozen-lockfile
swift run CodexUsage
```

For automatic restart while editing Swift sources:

```sh
bun run dev:watch
```

The test-notification controls appear only in Debug builds.

## Packaging

```sh
bun run package:app
```

The script builds `dist/CodexUsage.app`. `BUNDLE_IDENTIFIER`, `OUTPUT_DIR`, `VERSION`, and `BUILD_NUMBER` can override packaging metadata. For Developer ID signing and notarization, store a `notarytool` profile and provide `APPLE_SIGNING_IDENTITY` plus `APPLE_NOTARY_KEYCHAIN_PROFILE`; the script uses hardened runtime, submits for notarization, staples the ticket, and runs Gatekeeper verification.

## Releases and updates

Release Please maintains the only release PR. Once its version, changelog, and required checks are approved and merged, GitHub Actions revalidates the merge, tests the Swift and TypeScript code, builds the app, creates `vX.Y.Z`, and publishes the DMG, updater ZIP, checksums, and GitHub Release. Direct pushes, manual tags, local packaging, and workflow dispatch are not formal release paths. See [Releasing](RELEASING.md).

The app compares its `CFBundleShortVersionString` with the latest public GitHub Release. If a `CodexUsage*.zip` asset exists, installed builds can download, replace, and relaunch the application. `swift run` builds open the release page instead of replacing themselves.

## Widget setup

1. Create a macOS Widget Extension named `CodexUsageWidgetExtension` in Xcode.
2. Add `WidgetExtension/CodexUsageWidget.swift` to that target.
3. Add the same App Group entitlement to the app and widget.
4. Keep the group ID aligned with `SharedSnapshotStore.appGroupIdentifier`.

Without an App Group, the menu-bar app still works and stores its snapshot in standard `UserDefaults`; the widget cannot read it.

## Community

Use [GitHub Issues](https://github.com/cixiangtao/codex-usage/issues) for ordinary bugs and feature requests, read [Contributing](CONTRIBUTING.md) before submitting code, and report credential, privacy, updater, or release-chain vulnerabilities through [Security](SECURITY.md).

## License

[MIT](LICENSE) © 2026 cixiangtao. Third-party attributions are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
