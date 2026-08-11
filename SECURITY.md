# 安全说明

## 永远不要提交的内容

- 第三方或 OpenAI API 密钥、Bearer token、Cookie、登录缓存。
- `/etc/codex-remote-provider/provider.env` 以及其 `providers/` 子目录中的内容。
- macOS Keychain 或 Windows DPAPI 解密后的第三方令牌。
- 完整进程环境、systemd manager environment、会话 JSONL 或未经脱敏的日志。
- 服务器公网 IP、内部主机名、会话 ID 等不需要公开的运行信息。

密钥只能在目标机器上交互输入，或由该机器的受控秘密管理环境注入；不得放入命令行、
仓库或日志。GitHub Actions 会检查常见高熵密钥形式，但自动扫描不是绝对保证；提交前
仍需人工检查 `git diff --cached`。

Linux 为每个地址保存独立的 root-only 密钥文件，并将当前选中地址复制到活动
`EnvironmentFile`。密钥均写成单行、双引号包围的变量，状态检查会按允许字符
安全解析该行，不会把文件作为 shell 脚本执行。调用接口时 Authorization header
通过权限为 0600 的临时文件交给 curl，避免把密钥直接放进进程命令行。

Linux 的状态文件和 Provider record 只有在确认是 root 所有、权限 `0600` 的普通文件
后才会解析；Provider/密钥目录必须是 `0700` 的真实目录而不能是符号链接。所有权
清单只授权精确的 Provider 路径：清单外 `.env` 和 profile 不会被遍历、接管或删除，
也不会阻断操作；新增或受管精确路径发生类型、标记或内容冲突时会 fail closed。
首次安装时唯一允许覆盖的重叠 profile 会先备份，回滚时恢复；非受管 launcher 和
替换受管路径的符号链接不会被静默覆盖。

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

## 密钥泄露后的处理

1. 立即在供应商后台吊销旧密钥，生成新密钥。
2. Linux 在服务器运行 `sudo codex-rp rotate-key`，为当前 Provider 输入新密钥；若
   要处理非当前地址，使用 `sudo codex-rp reconfigure`。不要只编辑活动
   `provider.env`，否则会与该地址的持久密钥副本失去同步。
3. 第三方模式会自动重启并完成检查；官方模式下可切回第三方后运行
   `sudo codex-rp test` 验证。
4. 如果密钥进入 Git 历史，除了吊销密钥，还要清理历史并检查所有 fork、构建
   日志和制品；仅删除最新文件不够。

macOS/Windows 使用 `codex-rp rotate-key` 更新系统凭据，再执行 `restart-app` 和
`test`。确认新密钥可用后立即吊销旧密钥；不要直接把明文密钥写进配置文件。

## 报告问题

提交 Issue 时只附脱敏日志。把令牌、IP、用户名、主机名、会话 ID 替换为
`<redacted>`，并只保留复现所需的最少上下文。
