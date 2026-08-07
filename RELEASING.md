# Releasing CodexUsage

GitHub Actions is the only formal publisher. A release is admitted only after a dedicated release
pull request is merged into `master`; unrelated open pull requests do not block a release.

## Prepare the release pull request

1. Synchronize a clean `master` branch with `origin/master`.
2. Choose the next stable SemVer version and create `release/vX.Y.Z` from `master`.
3. Run `bun run release:prepare -- X.Y.Z`, then `bun install --lockfile-only`.
4. Commit only `package.json` and `bun.lock` as `chore: release vX.Y.Z`.
5. Push the branch and open a pull request targeting `master`.
6. Wait for the required CI checks, review the release-only diff, and merge that pull request.

The release workflow verifies the merged PR, its branch name, its changed files, and the version
change before building. It then creates `vX.Y.Z` at the approved merge commit and publishes the
DMG, ZIP, checksums, and GitHub Release in the same Actions chain.

Direct pushes, manually created tags, and workflow dispatches are not release entry points.

## Verify and recover

After the workflow succeeds, verify the remote tag, GitHub Release flags and assets, downloaded
checksums, archive integrity, and application launch. If a run fails, inspect the existing tag,
Release, and assets before rerunning the same workflow; do not publish locally or reuse a version.
