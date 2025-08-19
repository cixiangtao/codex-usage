# Codex 用量

一个原生 macOS 状态栏应用，用于展示本地 Codex 最新用量快照，包括剩余百分比、重置时间、通知提醒，以及可供 WidgetKit 小组件读取的共享状态。

## 当前功能

- 状态栏显示 Codex 剩余额度。
- 状态栏默认同时显示 `5h` 和 `7d` 剩余额度，使用 `5h 86% · 7d 88%` 这类紧凑格式；也可在设置中勾选要展示的窗口，并控制是否展示窗口标签。
- 展开面板查看 `5h` / `7d` 额度窗口。
- 后台解析 `~/.codex/sessions/**/*.jsonl` 中的 token-count 事件，避免刷新时卡住界面。
- 支持低剩余额度通知阈值。
- 保存共享快照，供 WidgetKit 小组件读取。
- `WidgetExtension/` 中提供小组件源码骨架。

## 数据来源说明

OpenAI 当前 Codex 文档描述了套餐访问、本地登录、API Key 计费和 Enterprise 审计/监控 API，但没有公开个人 Plus/Pro/Go 套餐精确剩余额度查询 API。因此应用会读取 Codex 已经写入本地会话日志的结构化 `rate_limits` 快照。每日 token 趋势优先读取 `~/.codex/state_5.sqlite` 中的线程级 `tokens_used` 汇总，以贴近 Codex 个人资料页统计；如果该数据库不可用，再回退解析 `~/.codex/sessions/**/*.jsonl` 的 token-count 事件。由于个人资料页统计来自服务端口径，本地趋势仍可能有轻微差异。它不会读取 `~/.codex/auth.json`。

## 本地运行

```sh
swift run CodexUsage
```

这个仓库是 Swift Package，不需要生成 Xcode 工程也能编译运行。要发布为带小组件的签名 `.app`，需要用 Xcode 打开包，添加 macOS Widget Extension target，然后把 `WidgetExtension/CodexUsageWidget.swift` 加入该 target。

首次使用开发、打包或发布脚本前，先安装 Bun 脚本依赖：

```sh
bun install
```

开发时可以使用 watch 脚本自动重启应用：

```sh
bun run dev:watch
```

脚本会监听 `Package.swift`、`Sources/` 和 `WidgetExtension/` 下的 Swift 文件变化。保存后会停止当前 `CodexUsage` 进程并重新执行 `swift run CodexUsage`，省去手动重启。

设置里的测试通知按钮只会在 Debug 构建中展示，`swift run CodexUsage` 和 `bun run dev:watch` 可见；release 打包后的 `.app` 不会展示。

## 打包

```sh
bun run package:app
```

脚本会执行 `swift build -c release`，并生成 `dist/CodexUsage.app`。可以用环境变量覆盖包标识和输出目录：

```sh
BUNDLE_IDENTIFIER=com.example.CodexUsage OUTPUT_DIR=/tmp bun run package:app
```

发布版本时建议同时写入 app 版本号和构建号：

```sh
VERSION=1.2.3 BUILD_NUMBER=456 bun run package:app
```

发布时把 GitLab token 放在环境变量里，不要写入仓库：

```sh
read -s GITLAB_TOKEN
export GITLAB_TOKEN
bun run release:local
unset GITLAB_TOKEN
```

也可以在本机创建不会提交的 `.env.local`：

```sh
GITLAB_TOKEN=你的 GitLab token
```

脚本会读取 `package.json` 的当前版本，交互式选择 patch、minor、major、current 或 custom 版本，并用 `semver` 校验版本号。确认后会同步 `package.json`/`bun.lock` 版本，生成 `dist/CodexUsage-vX.Y.Z.zip`，上传到 GitLab Generic Package Registry，并把 zip 挂到对应 GitLab Release 的 asset 上。`GITLAB_TOKEN` 会优先从环境变量读取，也会自动读取本机 `.env.local`；如果都没有设置，交互式命令会隐藏输入 token，不要写入仓库。

也可以跳过交互，直接指定版本和发布说明：

```sh
bun run release:local -- 1.2.3 "Release notes"
```

## 更新检测

设置窗口会从 GitLab Release API 检查最新版本：

```text
https://gitlab-ee.zhenguanyu.com/api/v4/projects/cixiangtao%2Fcodex-usage/releases/permalink/latest
```

应用会读取本地 `CFBundleShortVersionString`，和最新 Release 的 tag 版本比较；tag 建议使用 `v1.2.3` 这种语义化版本。检测到新版本后，设置页会提供下载入口，优先打开 Release asset 中的 `.zip` 包。

如果仓库是私有项目，app 内请求 GitLab API 时没有浏览器登录态，可能会检测失败。要公开分发时，可以把项目 Release 设为可匿名读取，或改为由 GitLab Pages 发布一个公开的 `latest.json` 更新清单。

## GitLab 发布

仓库内的 `.gitlab-ci.yml` 会在推送 tag 时执行发布流水线：

1. 使用 macOS Runner 执行 `bun run package:app`。
2. 将 `dist/CodexUsage.app` 打包成 `CodexUsage-vX.Y.Z.zip`。
3. 上传到 GitLab Generic Package Registry。
4. 创建 GitLab Release，并把 zip 作为 Release asset。

默认构建任务使用 `macos` runner tag。需要先在 GitLab EE 上注册一台带 Swift/Xcode 工具链的 macOS Runner，并给它设置 `macos` tag。上传和 Release 任务使用 Docker 镜像运行，如果 GitLab 实例没有可用的 Docker Runner，需要给这两个任务补充合适的 runner tag，或改成在 macOS Runner 上安装 `curl`/`glab` 后执行。

## 小组件设置

1. 在 Xcode 中创建名为 `CodexUsageWidgetExtension` 的 macOS Widget Extension。
2. 将 `WidgetExtension/CodexUsageWidget.swift` 加入小组件 target。
3. 给主 app 和小组件都添加 App Group entitlement，例如 `group.com.anys.codexusage`。
4. 保持 `SharedSnapshotStore.appGroupIdentifier` 中的 group id 一致。

没有 App Group entitlement 时，状态栏 app 仍可运行，并会把快照存在标准 `UserDefaults`；小组件需要 App Group 才能读取 app 写入的最新快照。
