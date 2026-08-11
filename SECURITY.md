# 安全说明

## 永远不要提交的内容

- 第三方或 OpenAI API 密钥、Bearer token、Cookie、登录缓存。
- `/etc/codex-remote-provider/provider.env` 的内容。
- macOS Keychain 或 Windows DPAPI 解密后的第三方令牌。
- 完整进程环境、systemd manager environment、会话 JSONL 或未经脱敏的日志。
- 服务器公网 IP、内部主机名、会话 ID 等不需要公开的运行信息。

密钥只能在目标服务器上交互输入。GitHub Actions 会检查常见高熵密钥形式，
但自动扫描不是绝对保证；提交前仍需人工检查 `git diff --cached`。

安装器将密钥写成单行、双引号包围的 `EnvironmentFile`，状态检查会按允许字符
安全解析该行，不会把文件作为 shell 脚本执行。调用接口时 Authorization header
通过权限为 0600 的临时文件交给 curl，避免把密钥直接放进进程命令行。

macOS 使用当前登录用户的 Keychain generic password；`config.toml` 只保存
`/usr/bin/security` 的查询参数。Windows 将密钥用当前用户 DPAPI 加密，配置只保存
受控解密助手和加密文件路径。两端都使用 Codex provider `auth.command`，不会把
Bearer token 写入 TOML、启动参数或 Remote 配对数据。

Windows 的 DPAPI 密文只能由加密它的同一 Windows 用户解密；不要用管理员账户替
实际登录 ChatGPT 的桌面用户安装。状态检查只验证解密结果格式，不打印令牌。
macOS 的 `/usr/bin/security` 与 Windows 解密助手都只在 Codex 请求认证时把令牌写到
受控子进程的 stdout；不要把这些命令改成写日志或永久明文文件。

桌面平台的 `restart-app` 必须由用户明确确认。它只重启 ChatGPT 应用以重新加载
配置，不执行退出登录、不删除设备配对，也不清理 Codex 会话。

macOS 的 `.app` 快捷入口不包含密钥、配置或会话数据；它只记录套件脚本的
绝对路径，并请 Terminal 打开中文管理面板。安装器只会替换带有套件标记的
同名 `.app`，不会覆盖用户的其他应用。

## 密钥泄露后的处理

1. 立即在供应商后台吊销旧密钥，生成新密钥。
2. 在服务器运行 `sudoedit /etc/codex-remote-provider/provider.env`，只替换值。
3. 运行 `sudo systemctl restart codex-remote-provider.service`。
4. 执行 `sudo ./status.sh --full`。
5. 如果密钥进入 Git 历史，除了吊销密钥，还要清理历史并检查所有 fork、构建
   日志和制品；仅删除最新文件不够。

macOS/Windows 使用 `codex-rp rotate-key` 更新系统凭据，再执行 `restart-app` 和
`test`。确认新密钥可用后立即吊销旧密钥；不要直接把明文密钥写进配置文件。

## 报告问题

提交 Issue 时只附脱敏日志。把令牌、IP、用户名、主机名、会话 ID 替换为
`<redacted>`，并只保留复现所需的最少上下文。
