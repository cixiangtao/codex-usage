# 参与贡献

[English](CONTRIBUTING.md) | 简体中文

感谢你帮助改进 CodexUsage。提交改动前，请先确认它符合原生 macOS 状态栏应用的定位，并且相较 `codex-bar` 在设计、运行行为、数据来源、系统集成或用户工作流上具有明确差异。

## 反馈问题

- 普通缺陷请使用 Bug report 模板，并附上应用版本、macOS 版本和最小复现步骤。
- 功能建议请说明要解决的用户问题，以及它与现有同类工具的差异价值。
- 安全问题请按照 [SECURITY.md](SECURITY.md) 私密报告，不要创建公开 Issue。
- 提交日志或截图前，请移除 access token、账号信息和本地路径中的敏感内容。

## 本地开发

环境要求：macOS 14 或更高版本、Swift 6 工具链和 Bun 1.3.14。

```sh
bun install --frozen-lockfile
swift build
swift test
bun run typecheck
```

涉及应用打包、资源或发布脚本时，再运行：

```sh
bun run package:app
```

## 提交 Pull Request

1. 保持改动聚焦，不要混入无关格式化或重构。
2. 为行为变化补充或更新测试，并同步相关文档。
3. 在 PR 中说明问题、实现方式、用户可见影响和已执行的验证。
4. 不要提交构建产物、凭据、个人数据或本机配置。
5. 不要自行修改版本号、创建 tag 或发布 Release；正式发布由维护者通过 GitHub Actions 执行。

提交 PR 即表示你同意按本仓库的 [MIT License](LICENSE) 提供所提交的内容。
