# Codex 用量

一个原生 macOS 状态栏应用，用于展示 Codex 最新用量快照，包括剩余百分比、重置时间、通知提醒，以及可供 WidgetKit 小组件读取的共享状态。

## 当前功能

- 状态栏显示 Codex 剩余额度。
- 状态栏默认同时显示 `5h` 和 `7d` 剩余额度，使用 `5h 86% · 7d 88%` 这类紧凑格式；也可在设置中勾选要展示的窗口，并控制是否展示窗口标签。
- 展开面板查看 `5h` / `7d` 额度窗口。
- 优先通过 Codex OAuth 凭据读取服务端用量窗口，失败时回退解析本地 `~/.codex/sessions/**/*.jsonl` 和 `~/.codex/archived_sessions/**/*.jsonl` 中的 token-count 事件。
- 支持低剩余额度通知阈值。
- 保存共享快照，供 WidgetKit 小组件读取。
- `WidgetExtension/` 中提供小组件源码骨架。

## 数据来源说明

应用会优先读取 `~/.codex/auth.json` 中 Codex CLI 已保存的 OAuth access token，并直接请求 `chatgpt.com` 的 Codex 用量接口获取 5h / 7d 用量窗口和重置卡信息。它不会读取、保存或上传密码，也不会把 token 写入应用自己的配置。

如果 OAuth 凭据不存在、过期或接口不可用，应用会回退读取 Codex 已经写入本地会话日志的结构化 `rate_limits` 快照。每日 token 趋势同样会先尝试接口数据；如果接口没有提供可用的每日 token 明细，再按本地 `sessions` / `archived_sessions` JSONL 的 token-count 事件时间聚合通用 Codex 用量，并尽量限定为当前登录账号：日志里有账号标识时要求匹配当前账号；没有账号标识时，只保留带额度窗口或 plan 信息的当前账号上下文事件。如果本地事件不可用，最后回退读取 `~/.codex/state_5.sqlite` 中的线程级 `tokens_used` 汇总。由于 Codex app / 个人资料页统计来自服务端口径，本地趋势仍可能和服务端日统计不完全一致。

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

默认构建会使用 ad-hoc 签名，适合本机调试，但从浏览器或 GitLab 下载后的 zip 会被 macOS 加上隔离标记，Gatekeeper 仍可能提示“Apple 无法验证 CodexUsage 是否包含恶意软件”。本机自用时可以在安装到 `/Applications` 后移除隔离标记：

```sh
xattr -dr com.apple.quarantine /Applications/CodexUsage.app
open /Applications/CodexUsage.app
```

要生成下载后可正常打开的发布包，需要使用 Apple Developer ID 证书签名并公证。先把 notarytool 凭据存到钥匙串：

```sh
xcrun notarytool store-credentials codex-usage-notary \
  --apple-id you@example.com \
  --team-id TEAMID12345 \
  --password app-specific-password
```

然后用 Developer ID 身份打包：

```sh
APPLE_SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID12345)" \
APPLE_NOTARY_KEYCHAIN_PROFILE=codex-usage-notary \
bun run package:app
```

脚本会在签名前清理常见 bundle 扩展属性，使用 hardened runtime 签名，提交 Apple 公证，staple 公证票据，并执行 Gatekeeper 校验。CI 或本地发布生成 zip 时会禁用资源叉和扩展属性，避免把本机 quarantine/provenance 元数据写进发布包。

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

本地发布由 `release-it` 编排。脚本会读取 `package.json` 的当前版本，交互式选择 patch、minor、major 或 custom 版本；确认后先用目标版本打包并生成 `dist/CodexUsage-vX.Y.Z.zip`。打包成功后才会更新 `package.json`/`bun.lock`、创建 release commit、打 `vX.Y.Z` tag、push，并把 zip 上传到 GitLab Generic Package Registry 后挂到对应 GitLab Release 的 asset 上。打包失败时版本文件不会被修改。`GITLAB_TOKEN` 会优先从环境变量读取，也会自动读取本机 `.env.local`；如果你只有 `PRIVATE_TOKEN`，脚本会兼容映射为 `GITLAB_TOKEN`。

也可以跳过交互，直接指定版本和发布说明：

```sh
bun run release:local -- 1.2.3 "Release notes"
```

## 更新检测

设置窗口会从 GitLab Release API 检查最新版本：

```text
https://gitlab-ee.zhenguanyu.com/api/v4/projects/cixiangtao%2Fcodex-usage/releases/permalink/latest
```

应用会读取本地 `CFBundleShortVersionString`，和最新 Release 的 tag 版本比较；tag 建议使用 `v1.2.3` 这种语义化版本。检测到新版本后，如果 Release asset 中包含 `CodexUsage*.zip`，设置页会提供“下载并安装”：应用会自动下载 zip、解压出新的 `.app`、退出当前进程、替换应用并重新打开。通过 `swift run` 启动的开发环境不能替换自身，会回退为打开发布页。

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
