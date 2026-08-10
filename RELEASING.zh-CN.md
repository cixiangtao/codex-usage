# 发布 CodexUsage

[English](RELEASING.md) | 简体中文

GitHub Actions 是唯一正式发布者。Release Please 自动创建或更新发版 PR；维护者不在本地提升版本、创建 tag 或打包正式版本。

## 正常流程

1. 普通改动通过 PR 和必需检查合入受保护的 `master`，无关 PR 可以继续保持打开。
2. Release Please 从 `release-please--branches--master--...` 分支维护唯一发版 PR，并根据 Conventional Commit 或 squash merge 标题生成 SemVer 版本与 `CHANGELOG.md`。
3. 检查发版 PR 的受限差异、版本、Changelog 和 CI，准备完成后合并。
4. `.github/workflows/release.yml` 重新验证这次合并，构建应用、创建 `vX.Y.Z`，并在同一条 Actions 链路中发布 DMG、ZIP、校验文件和 GitHub Release。
5. 独立验证远端 tag、Release 状态与资产、下载后的校验和、压缩包完整性和应用启动。

普通 PR 合并不会发布。直接推送、手工 tag 和 workflow dispatch 都不是发布入口。

## 自动化凭据与恢复

仓库使用 Actions variable `RELEASE_APP_CLIENT_ID` 和 secret `RELEASE_APP_PRIVATE_KEY`，对应一个已安装且具有 Contents、Issues、Pull requests 读写权限的 GitHub App。其短期 token 让发版 PR 的必需 CI 无人值守运行。

工作流失败时，先检查已合并发版 PR、现有 tag、Release 和资产，再重新运行同一个工作流。不得复用或覆盖已经公开的版本。
