# 安全说明

## 永远不要提交的内容

- 第三方或 OpenAI API 密钥、Bearer token、Cookie、登录缓存。
- `/etc/codex-remote-provider/provider.env` 的内容。
- 完整进程环境、systemd manager environment、会话 JSONL 或未经脱敏的日志。
- 服务器公网 IP、内部主机名、会话 ID 等不需要公开的运行信息。

密钥只能在目标服务器上交互输入。GitHub Actions 会检查常见高熵密钥形式，
但自动扫描不是绝对保证；提交前仍需人工检查 `git diff --cached`。

## 密钥泄露后的处理

1. 立即在供应商后台吊销旧密钥，生成新密钥。
2. 在服务器运行 `sudoedit /etc/codex-remote-provider/provider.env`，只替换值。
3. 运行 `sudo systemctl restart codex-remote-provider.service`。
4. 执行 `sudo ./status.sh --full`。
5. 如果密钥进入 Git 历史，除了吊销密钥，还要清理历史并检查所有 fork、构建
   日志和制品；仅删除最新文件不够。

## 报告问题

提交 Issue 时只附脱敏日志。把令牌、IP、用户名、主机名、会话 ID 替换为
`<redacted>`，并只保留复现所需的最少上下文。
