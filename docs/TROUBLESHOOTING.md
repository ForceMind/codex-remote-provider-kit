# 故障排查

Linux/systemd 宿主先运行：

```bash
sudo ./status.sh
sudo systemctl status codex-remote-provider.service --no-pager
```

`status.sh` 会显示 `third-party` 或 `official`。如果当前处于官方模式，直接查看
`codex-remote-official.service`；若两个 unit 同时 active 或都未运行，状态检查会
明确失败，而不是误报第三方可用。

## 切换后显示 `ActiveState=failed`

这表示目标 Remote unit 确实启动失败，不能把之前的“已启动”文案当作
成功。更新后的脚本会在输出成功文案前同时检查 `ActiveState` 和 `Result`；
目标 unit 异常时会报错并尝试恢复切换前的配置和服务模式。

在切换或重试前先保留脱敏诊断信息：

```bash
sudo systemctl status codex-remote-official.service --no-pager -l
sudo journalctl -u codex-remote-official.service -n 100 --no-pager
codex --version
codex login status
```

日志可能含主机名、用户目录或会话标识，对外提供前应脱敏；不要输出完整环境
变量，也不要删除 Codex session 来规避故障。

## 启动时自动更新失败

自动更新默认为失败开放：下载、语法校验或事务替换失败时会显示警告，然后
继续启动当前本地版本。先检查服务器是否可通过 HTTPS 访问 `raw.githubusercontent.com`
和 `github.com`，以及安装目录的父目录是否可写。不要为此输出代理凭据或完整
环境变量。

需要在断网环境中直接打开面板时：

```bash
CODEX_RP_SKIP_AUTO_UPDATE=1 codex-rp
```

如果当前版本早于自动更新功能，它不会凭空获得新启动器；需先手工重跑一次
README 中的在线安装命令。Git 工作区和手工解压目录没有在线安装源标识，
因此不会自动更新。

macOS/Windows 先运行 `codex-rp status`。Remote 宿主必须是最新版 ChatGPT 桌面
应用，并与手机登录同一账号/workspace；移动端 Remote 配对需要从桌面应用的
`Settings > Connections` 开始，不能用本工具替代官方配对流程。

## macOS 快捷启动图标缺失或无法打开

运行 `codex-rp shortcut` 重建
`~/Applications/Codex 远程模型服务工具.app`。它会打开 Terminal 并运行管理面板。
旧的受管英文入口会自动迁移；若目标路径
已有不受本套件管理的同名 `.app`，脚本会拒绝覆盖；请先自行改名或移动该应用。

如果快捷入口可以打开但 Finder/Dock 仍显示旧图标，先运行 `codex-rp shortcut`，
再把 Dock 中的旧图标移除并从 `~/Applications` 重新拖入。脚本在原子替换 bundle 后会
更新其修改时间，但 macOS 的 Dock 图标缓存可能仍需重新添加才会刷新。

## macOS 写入 Keychain 时显示 `add-generic-password` Usage

旧版 macOS 安装器未向 `/usr/bin/security` 提供必需的 account 参数，会在输入密钥后
只显示 `add-generic-password` 用法并回滚。必须先重新运行 README 中的在线安装命令
刷新已安装的工具目录，再从新版中文面板选择 `1`；直接调用旧的
`codex-rp install` 不会更新脚本自身，可能重复同一错误。新版会同时使用 provider ID
作为 Keychain account，并通过标准输入写入密钥，避免把密钥放进进程命令行。安装
失败后的自动回滚不会保留新建凭据或部分 provider 配置，因此不需要先手工回滚。

必须以实际登录 ChatGPT 的桌面用户在普通 Terminal 中运行，不要用 `sudo`。如果系统
拒绝 Keychain 交互，请先确认登录钥匙串已经解锁，再重新执行安装。

## macOS 提示检测到 CC Switch 或外部 provider

这是写入保护，不是自动故障转移。先在 CC Switch 中明确切换到 OpenAI 官方配置，
确认 `model_provider` 为 `openai` 或未设置，再重新执行原操作。不要直接删除 CC Switch
配置，也不要让两个工具同时切换。

如果 `status` 同时提示受管 provider 配置缺失或被修改，说明外部工具可能重写了
本工具带标记的 provider 区块。保持官方模式并执行 `codex-rp rollback`；若回滚报告
同名 provider 或 profile 所有权不明确，应先在 CC Switch 中把冲突项改名，不能强制
覆盖。回滚会保留不冲突的其他 provider。

## macOS/Windows 切换后仍使用旧 provider

桌面切换默认不会自动关闭 ChatGPT。运行 `codex-rp restart-app`，确认短暂断开后
重新连接，再创建新会话。已有活跃会话可能保留切换前的 app-server/provider，不要
同时在手机和桌面继续写同一会话。

macOS 可在“钥匙串访问”中确认服务名 `codex-remote-provider-kit:<provider-id>`；
Windows 可确认 `%LOCALAPPDATA%\CodexRemoteProviderKit\active\provider.key` 存在。
不要打印、复制或手工解密令牌。凭据损坏时使用 `codex-rp rotate-key`。

若 Windows 状态显示“当前用户无法解密”，通常是换了 Windows 用户运行工具，或把
另一个用户生成的 `provider.key` 复制了过来。请切回最初安装的桌面用户；跨用户迁移
时应执行回滚后重新安装并输入新密钥，不要复制 DPAPI 密文。

## Windows 与 WSL 配置不一致

Windows ChatGPT 应用使用 `%USERPROFILE%\.codex`。WSL2 的 Codex 默认使用 Linux
`~/.codex`，不会自动共享配置、认证或会话。若确实需要从 WSL 使用同一目录，按
OpenAI 官方说明设置 `CODEX_HOME`；不要同时运行 Windows 原生和 WSL 两套安装器
修改同一文件。

## 新机器无法自动安装 Codex

自动安装需要 root 权限、systemd，以及 `apt-get`、`dnf`、`yum` 其中之一。
若发行版不在支持范围内，请先按照该系统的方式安装 `curl` 和 Python 3，再执行
OpenAI 官方安装命令：

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
sudo ./setup.sh codex
```

服务器没有图形界面时，脚本会优先使用 `codex login --device-auth`，在终端显示
登录网址和设备代码。登录完成后必须确保 `codex login status` 显示
`Logged in using ChatGPT`；仅使用 API key 登录不能满足 Remote 配对要求。

## 已登录但安装器报告未登录

先运行 `codex login status`，确认输出包含 `Logged in using ChatGPT`。旧版本安装器
在 `pipefail` 下使用提前退出的管道检查，并丢弃了 Codex 0.147.0 写到 stderr 的
状态文本，可能把成功登录误判为失败；更新仓库后重新运行 `codex-rp` 即可。
API key 登录不能替代 Remote 所需的 ChatGPT 登录。

## 手机显示“加载消息时出错 / Codex 服务器返回错误”

按顺序检查：

1. 服务是否为 active，Remote 是否已经成功连接。
2. `sudo ./status.sh --full` 是否能完成 Responses 与真实 Codex 调用。
3. 手机上新建会话，不要继续使用报错的旧会话。
4. 确认没有本地 Codex 或第二个 Remote 进程正在写同一会话。
5. 若第三方宕机，运行 `use-official.sh` 人工回退。

## 新会话仍显示 `model_provider=openai`

Remote 的 `start` 命令会引导一个独立的托管 app-server daemon。只给引导命令
传递临时 `-c model_provider=...`，不保证该值被后台 daemon 继承。必须确认用户级
`$CODEX_HOME/config.toml` 顶层包含：

```toml
model_provider = "third_party"
```

同时确认顶层 `model` 和 `model_reasoning_effort` 与安装参数一致，然后完整停止并
重新启动 Remote，再创建新会话。`status.sh` 会检查这三个默认值。切换脚本也会
先更新整组默认值，再重启 daemon。

## `/v1/models` 成功，但 `/v1/responses` 报 Input must be a list

模型目录与推理接口是两套校验。直接测试 Responses 时需使用数组并启用流式
响应，例如：

```json
{
  "model": "gpt-5.6-sol",
  "input": [{"role": "user", "content": "Reply exactly OK"}],
  "stream": true
}
```

不要把真实 Authorization header 写入文档、Issue 或聊天。优先使用
`status.sh --full`，它会从 root-only 文件读取密钥且不打印值。

## 日志出现模型列表刷新错误，但实际回复正常

部分兼容网关的 `/v1/models` 返回 `{ "data": [...] }`，而当前 Remote 的可选
目录刷新可能期待另一个字段。这可以是非致命错误。判断可用性的标准是：

- `status.sh --full` 的 Responses 检查成功；
- 临时 `codex exec` 返回 OK；
- 手机新会话能收到回复。

如果其中任一失败，不能把刷新错误当作无害。

## `thread-store conflict` 或 `already has an active writer`

同一个线程正被另一个 Codex 进程持有。关闭本地正在打开该线程的 Codex，确保
只运行一个 Remote daemon，然后在手机上新建会话。不要删除 session 文件；这
会丢失历史且不解决多进程根因。

## systemd 报 `203/EXEC`

unit 中的 Codex 路径不存在或不可执行。检查：

```bash
command -v codex
sudo systemctl cat codex-remote-provider.service
```

重新安装时通过 `--codex-bin /实际/路径/codex` 指定绝对路径。修改 unit 后执行
`sudo systemctl daemon-reload`。

## Remote 连接被拒绝或残留 daemon

先使用官方 stop 命令，再重启服务：

```bash
sudo /实际/路径/codex remote-control stop --json
sudo systemctl restart codex-remote-provider.service
```

仍失败时检查进程与日志。只终止已经确认属于 Remote 的精确 PID，不要使用宽泛
的进程名批量杀死，也不要删除会话目录。

## `401` / `403`

常见原因是密钥过期、权限不足、环境变量名与 provider 配置不一致。轮换密钥后
重启服务。排查时只检查“变量是否存在”和 HTTP 状态，不输出变量值。

## 安装器拒绝 HTTP Base URL

这是默认安全策略：API 密钥和模型内容不能通过明文 HTTP 发送。生产、互联网和
普通局域网环境都应使用 HTTPS。只有隔离的本机兼容性测试可在明确理解风险后，
通过命令行增加 `--allow-http`；面板不会默认放宽此限制。

## 粘贴 API Key 时没有显示，随后提示字符不支持

密钥输入使用静默模式，键入或粘贴时不显示任何字符是正常的；按回车后会显示
已接收字符数和“内容已隐藏”，用来确认粘贴成功。脚本支持常见的 URL-safe 和
带 `=` 填充的 Base64 密钥。请只复制密钥本身，不要包含前后空格、引号、
`export NAME=` 前缀或额外换行，也不要把密钥粘贴到聊天或 Issue。

## `429`、超时或 `5xx`

这是配额、限流或上游故障。先间隔重试并查看供应商状态；业务必须继续时，人工
执行 `use-official.sh`。恢复后再 `use-third-party.sh` 并运行完整检查。

## 回退也无法恢复

运行 `rollback.sh` 恢复安装前状态，并查看备份目录。若要提交 Issue，请使用
仓库模板，仅附脱敏后的版本号、HTTP 状态、时间和最少日志。

成功回滚后，活动 `state.env` 会移入同目录的 `audit/`，因此可以直接重新安装。
如果安装中途失败，安装器会自动尝试恢复原文件和服务，并保留故障前备份目录；
先检查恢复提示和脱敏日志，不要手工删除 Codex 会话。
