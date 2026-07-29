# 安全政策

## 支持范围

安全修复以最新 GitHub Release 为目标。旧版本用户应先升级到最新版，再确认问题是否仍然存在。

以下问题尤其适合通过安全渠道报告：

- Codex OAuth 凭据或本地会话数据可能被意外泄露；
- 自动更新下载、校验、解压或应用替换流程可能被利用；
- 发布产物、签名或 GitHub Actions 发布链存在完整性问题；
- 应用访问了文档所述范围以外的敏感数据。

## 报告漏洞

请使用 GitHub 的[私密漏洞报告](https://github.com/cixiangtao/codex-usage/security/advisories/new)，不要创建公开 Issue，也不要在报告中粘贴真实 access token、密码或其他凭据。

报告中请尽量包含：

- 受影响版本和 macOS 版本；
- 问题影响及可复现步骤；
- 必要的最小日志、截图或概念验证，且已移除敏感信息；
- 已尝试的缓解方式。

维护者会通过 GitHub Security Advisory 与报告者继续沟通。项目目前不承诺固定响应时限或漏洞奖励。
