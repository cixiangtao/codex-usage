# Releasing CodexUsage

English | [简体中文](RELEASING.zh-CN.md)

GitHub Actions is the only formal publisher. Release Please automatically creates or updates the
release pull request; maintainers do not bump versions, create tags, or package a release locally.

## Normal flow

1. Merge ordinary changes into protected `master` through pull requests and required checks.
   Unrelated open pull requests may remain open.
2. Release Please updates one automated release PR from a
   `release-please--branches--master--...` branch. Conventional commit or squash-merge titles
   determine the proposed SemVer version and `CHANGELOG.md` (`fix` = patch, `feat` = minor, and
   `!` or `BREAKING CHANGE` = major).
3. Review the release-only diff, version, changelog, and CI, then merge the release PR when ready.
4. `.github/workflows/release.yml` revalidates that exact merge, builds the application, creates
   `vX.Y.Z`, and publishes the DMG, ZIP, checksums, and GitHub Release in one Actions chain.
5. Verify the remote tag target, GitHub Release flags and assets, downloaded checksums, archive
   integrity, and application launch.

A regular PR merge never publishes. Direct pushes, manually created tags, and workflow dispatches
are not release entry points.

## Automation credentials and recovery

Define the Actions variable `RELEASE_APP_CLIENT_ID` and secret `RELEASE_APP_PRIVATE_KEY` for a
GitHub App installed on this repository with Contents, Issues, and Pull requests read/write
permissions. Its token lets required CI run unattended; PR checks created with the default
`GITHUB_TOKEN` currently wait for separate workflow approval.

If a run fails, inspect the merged release PR, existing tag, Release, and assets before rerunning
the same workflow. Never reuse or overwrite a published version.
