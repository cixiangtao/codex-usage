# AGENTS.md

## Project

`codex-usage` is a native macOS menu bar app for monitoring Codex usage, notifications, and widget-readable snapshots.

## Commands

- `swift build`: compile the Swift package.
- `swift run CodexUsage`: run the debug menu bar app.
- `bun run dev:watch`: restart the debug app when Swift sources change.
- `bun run package:app`: build `dist/CodexUsage.app`.

## Rules

- Keep this app meaningfully differentiated from `codex-bar`. Do not add features that merely recreate `codex-bar` unless the design, runtime behavior, data source, native integration, or user workflow is clearly better or different enough to justify this product existing.
- Prefer native macOS behavior and system integrations when they fit the requirement.
- Keep status bar copy concise, with detailed state and actions inside the menu or settings window.
- Centralize user-facing quota window naming instead of scattering equivalent labels.
- Keep changes focused and aligned with the existing Swift Package structure.

## Verification

Run the narrowest relevant check before handoff:

- Swift source changes: `swift build`.
- Packaging or release script changes: `bun run package:app`.
- Documentation-only changes: no build required unless the surrounding change also touched code.
