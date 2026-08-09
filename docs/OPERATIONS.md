# 日常运维手册

以下命令默认在本仓库目录执行，并需要 root 权限。

## 一键安装和统一入口

新服务器克隆仓库后执行：

```bash
./panel.sh
```

也可以跳过面板直接一键安装：

```bash
sudo ./setup.sh install
```

安装成功后无需再进入仓库目录。在任意目录运行以下命令即可打开管理面板：

```bash
codex-rp
```

Remote 由 `codex-remote-provider.service` 在后台托管并开机自启，关闭面板不会
停止服务。

脚本会提示输入密钥，随后安装、启动并执行完整验证。日常管理也可以全部通过
同一入口完成：

```bash
sudo ./setup.sh status
sudo ./setup.sh test
sudo ./setup.sh official
sudo ./setup.sh third-party
sudo ./setup.sh rollback
```

第一次安装需要终端交互，不能在无人值守任务中把密钥直接写进命令行。若要
自动化部署，应由服务器的秘密管理系统预先注入 `INNO_FLARE_API_KEY` 环境变量，
再运行 `sudo -E ./setup.sh`，并确保 CI 日志不会打印环境内容。

## 每次变更后的标准检查

```bash
sudo ./status.sh
sudo ./status.sh --full
```

检查成功后，再在手机上创建一个新会话测试。`--full` 会发起一次很小的真实
模型调用；基础检查不会生成模型回复。

## 查看状态与脱敏日志

```bash
sudo systemctl status codex-remote-provider.service --no-pager
sudo journalctl -u codex-remote-provider.service -n 100 --no-pager
```

粘贴日志到 Issue 或聊天前，必须删除令牌、主机名、IP、用户目录、会话 ID 和
业务代码。不要运行会输出完整环境变量的命令。

## 第三方与官方之间切换

切到官方默认 provider：

```bash
sudo ./use-official.sh
```

这一步可能使用官方额度。切回第三方：

```bash
sudo ./use-third-party.sh
sudo ./status.sh --full
```

## 密钥轮换

先在供应商后台生成新密钥，然后：

```bash
sudoedit /etc/codex-remote-provider/provider.env
sudo chmod 600 /etc/codex-remote-provider/provider.env
sudo systemctl restart codex-remote-provider.service
sudo ./status.sh --full
```

文件只保留一行 `<环境变量名>=<新密钥>`，不要加 `export`。确认新密钥正常后
立即吊销旧密钥。

## Codex 升级

1. 记录当前 `codex --version` 和 `status.sh --full` 结果。
2. 升级 Codex CLI。
3. 检查 `codex remote-control start --help` 是否仍存在。
4. 重启服务并运行 `status.sh --full`。
5. 用手机新会话验证，不要先复用旧的活跃会话。

若升级后不兼容，先切回官方，或恢复先前 Codex 版本；不要通过删除会话历史来
绕过写入冲突。

## 迁移到另一台服务器

1. 克隆本仓库，不要复制旧服务器的密钥文件或会话目录。
2. 在新服务器登录 ChatGPT/Codex。
3. 创建一枚新的第三方密钥。
4. 按 README 的安装步骤运行。
5. 执行基础检查、完整检查和手机新会话测试。
6. 确认新服务器稳定后，再停用旧服务器 Remote，避免两个进程争用同一会话。

也可以把 `MIGRATION_PROMPT.md` 交给新服务器上的 Codex，让它按安全流程协助。

## 完整撤销

```bash
sudo ./rollback.sh
```

脚本会恢复备份、移除持久化密钥和自定义 unit，并恢复安装前旧服务的启用/运行
状态。审计状态文件会保留，不含 API 密钥。
