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

开发时可以使用 watch 脚本自动重启应用：

```sh
scripts/dev-watch.sh
```

脚本会监听 `Package.swift`、`Sources/` 和 `WidgetExtension/` 下的 Swift 文件变化。保存后会停止当前 `CodexUsage` 进程并重新执行 `swift run CodexUsage`，省去手动重启。

设置里的测试通知按钮只会在 Debug 构建中展示，`swift run CodexUsage` 和 `scripts/dev-watch.sh` 可见；release 打包后的 `.app` 不会展示。

## 打包

```sh
scripts/package-app.sh
```

脚本会执行 `swift build -c release`，并生成 `dist/CodexUsage.app`。可以用环境变量覆盖包标识和输出目录：

```sh
BUNDLE_IDENTIFIER=com.example.CodexUsage OUTPUT_DIR=/tmp scripts/package-app.sh
```

## 小组件设置

1. 在 Xcode 中创建名为 `CodexUsageWidgetExtension` 的 macOS Widget Extension。
2. 将 `WidgetExtension/CodexUsageWidget.swift` 加入小组件 target。
3. 给主 app 和小组件都添加 App Group entitlement，例如 `group.com.anys.codexusage`。
4. 保持 `SharedSnapshotStore.appGroupIdentifier` 中的 group id 一致。

没有 App Group entitlement 时，状态栏 app 仍可运行，并会把快照存在标准 `UserDefaults`；小组件需要 App Group 才能读取 app 写入的最新快照。
