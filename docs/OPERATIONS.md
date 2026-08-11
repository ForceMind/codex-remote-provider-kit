# 日常运维手册

Linux 命令默认在本仓库目录执行并需要 root 权限；macOS/Windows 使用当前桌面
用户运行 `codex-rp`，不要使用 sudo 或管理员账户替代实际登录 ChatGPT 的用户。

## macOS/Windows 桌面 Remote 标准流程

1. 在最新版 ChatGPT 桌面应用登录手机所用的同一账号和 workspace。
2. 在 `Settings > Connections` 中启用 `Control this Mac/PC` 并用手机配对。
3. 运行 `codex-rp install`，密钥只进入 Keychain 或 DPAPI。
4. 运行 `codex-rp status`，确认三项默认配置和系统凭据存在。
5. 明确运行 `codex-rp restart-app`；当前 Remote 会短暂断开，但不会注销或删除配对。
6. 运行 `codex-rp test`，再从手机创建一个新会话验证。

日常命令在两个桌面平台保持一致：

```text
codex-rp status
codex-rp test
codex-rp official
codex-rp third-party
codex-rp rotate-key
codex-rp restart-app
codex-rp rollback
```

桌面端的 `official` 是兼容命令名，实际行为是恢复安装前保存的三项默认配置；工具
无法验证这组原始值一定指向 OpenAI，因此状态显示为 `baseline`。首次安装前应先
确认桌面 Codex 使用所需默认模式，并保留安装器生成的备份。

切换命令本身不重启应用，避免无提示中断 Remote。macOS/Windows 目前仍按旧
provider 语义切换，配置只保证影响新任务；执行 `restart-app` 后从手机新建会话，
不要把 Linux 的稳定会话 ID 行为套用到桌面平台。

Windows 必须以实际登录 ChatGPT 的普通桌面用户运行；DPAPI 密文不能由另一用户或
管理员账户代为解密。macOS 同样应使用实际桌面用户，以便 `auth.command` 访问正确
Keychain。三项默认配置在两个平台都作为一次事务更新。

## 一键安装和统一入口

新服务器克隆仓库后执行：

```bash
./panel.sh
```

菜单第 1 项是从零部署入口：会安装缺少的系统依赖，并调用 OpenAI 官方独立
安装器准备 Codex，引导 ChatGPT 设备登录，然后继续安装第三方 Remote。仅准备
Codex 时可运行：

```bash
sudo ./setup.sh codex
```

自动依赖安装支持 Debian/Ubuntu 的 `apt-get`，以及使用 `dnf` 或 `yum` 的
RHEL 系发行版。其他发行版需要先手工安装 `curl` 和 Python 3，
然后重新运行面板。

也可以跳过面板直接一键安装：

```bash
sudo ./setup.sh install
```

安装成功后无需再进入仓库目录。在任意目录运行以下命令即可打开管理面板：

```bash
codex-rp
```

安装会创建第三方 `codex-remote-provider.service` 与官方
`codex-remote-official.service`，并且只启用当前所选模式。关闭面板不会停止
Remote；人工切换后的模式会跨系统重启保持。

脚本会提示输入密钥，随后安装、启动并执行完整验证。日常管理也可以全部通过
同一入口完成：

```bash
sudo ./setup.sh status
sudo ./setup.sh test
sudo ./setup.sh official
sudo ./setup.sh third-party
sudo ./setup.sh rollback
```

Linux 面板的“选择 / 切换第三方供应商”会列出注册表中的所有地址。选择已有地址
不会再次询问 Key。要保存新地址，选择“新增 / 更新第三方地址”，填写 Base URL、
模型、推理强度和该地址的 Key；旧地址及其 Key 会继续保留。
列表只来自 `state.env` 的受管 Provider 清单；手工放入注册表目录的 `.env` 不会显示、
不会被切换，也不会在回滚时删除。不要用符号链接替换 record、secret 或 profile；
检测到精确路径冲突时工具会停止，并要求管理员先核实文件来源。

状态中的 `PROVIDER_ID` 表示当前具体第三方注册记录；`SESSION_PROVIDER_ID` 是首次
安装或旧版首次升级时固定的会话身份。以后选择其他地址只改变前者。官方模式和
第三方模式会把同一个 `SESSION_PROVIDER_ID` 分别绑定到官方 Codex 端点或当前网关。

第一次安装需要终端交互，不能在无人值守任务中把密钥直接写进命令行。若要
自动化部署，应由服务器的秘密管理系统预先注入 `THIRD_PARTY_API_KEY` 环境变量，
再运行 `sudo -E ./setup.sh`，并确保 CI 日志不会打印环境内容。

## 每次变更后的标准检查

```bash
sudo ./status.sh
sudo ./status.sh --full
```

`--full` 会发起一次很小的真实模型调用；基础检查不会生成模型回复。首次安装可在
手机上创建新会话测试；Linux 日常切换时，已使用稳定 ID 的 thread 应在短暂重连后
先尝试继续，不可见时按 thread ID 显式恢复，只有恢复失败时才新建。

## 查看状态与脱敏日志

```bash
sudo systemctl status codex-remote-provider.service --no-pager
sudo journalctl -u codex-remote-provider.service -n 100 --no-pager
```

若当前处于官方模式，将上述 unit 名替换为
`codex-remote-official.service`；`sudo ./status.sh` 会直接显示当前模式。

粘贴日志到 Issue 或聊天前，必须删除令牌、主机名、IP、用户目录、会话 ID 和
业务代码。不要运行会输出完整环境变量的命令。

## 第三方与官方之间切换

先等当前 turn 完整结束，确认没有工具调用或回复仍在运行，再执行切换。切换过程中
Remote daemon 会重启，手机会短暂断线；若原 thread 已使用稳定 ID，重连后先在该
thread 继续发送消息，不可见时再按下述方法显式恢复。

切到同一稳定会话 ID 对应的官方推理端点：

```bash
sudo ./use-official.sh
```

这一步可能使用官方额度。切回第三方：

```bash
sudo ./use-third-party.sh
sudo ./status.sh --full
```

切换脚本会刷新两个 unit、停止另一模式并修改开机启用状态。项目不执行自动
故障转移。若目标服务启动失败，脚本会尝试恢复切换前的配置和服务模式。官方
模式下运行 `status.sh --full` 也不会生成回复，以免意外消耗额度。两种 unit 都使用
同一个 `SESSION_PROVIDER_ID`；这能保留 Provider 过滤身份，但不能替代真实手机链路
验证或显式恢复。

## 从旧版本升级套件

重新运行公开在线安装命令会替换 `/opt/codex-remote-provider-kit`，并备份旧目录。
随后打开新版面板或运行：

```bash
sudo ./setup.sh install
```

检测到现有状态时，脚本不会重写初始备份或密钥，而是通过 `refresh-units.sh`
刷新官方/第三方 unit 和 `codex-rp`，然后切回第三方模式并验证。旧状态若没有
`SESSION_PROVIDER_ID`，这次升级会把当时的当前 `PROVIDER_ID` 固定为稳定会话 ID；
后续升级和切换不再改变它。

升级前已经以 `openai` 或其他 provider ID 创建的历史可能被客户端 provider 过滤。
已知 thread ID 时，可在确保只有一个活跃写入者后显式恢复：

```bash
codex resume <THREAD_ID> --model <MODEL> \
  -c 'model_provider="<RECOVERY_PROVIDER_ID>"'
```

`RECOVERY_PROVIDER_ID` 必须在当前 Codex 配置中有效；通常使用当前
`SESSION_PROVIDER_ID`，需要沿用旧路由时才使用仍有定义和凭据的历史 ID。该命令
依据 [Codex 命令参考](https://learn.chatgpt.com/docs/developer-commands.md?surface=cli)
提供的显式会话 ID 与全局覆盖能力。本项目不改写 SQLite/JSONL，也没有官方批量
迁移 API；手工恢复失败时才创建新会话。

第三方接口默认必须是 HTTPS。仅隔离的本机测试可通过命令行显式增加
`--allow-http`；面向公网或局域网网关都不应使用明文 HTTP 传输密钥。

## 密钥轮换

先在供应商后台生成新密钥，然后从面板选择“仅修改第三方 API Key”，或运行：

```bash
codex-rp rotate-key
```

如需新增地址，或修改当前地址的模型和推理强度，运行：

```bash
codex-rp reconfigure
```

脚本会在同一事务中更新该地址的持久密钥和当前活动副本，并保留当前官方/第三方
模式；第三方正在运行时会重启并执行完整验证，官方模式下只保存配置，等下次切回
第三方时生效。不要只手工编辑活动 `provider.env`，否则它会与
`providers/<PROVIDER_ID>.env` 失去同步，后续切换、同步或回滚将安全停止。确认新密钥
正常后立即吊销旧密钥。

## Codex 升级

1. 记录当前 `codex --version` 和 `status.sh --full` 结果。
2. 升级 Codex CLI。
3. 检查 `codex remote-control start --help` 是否仍存在。
4. 重启服务并运行 `status.sh --full`。
5. 等原 turn 结束后，用手机在原 thread 继续验证；只有恢复失败时才新建会话。

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
状态。审计状态文件会移动到 `/var/lib/codex-remote-provider/audit/`，不含 API
密钥；活动状态文件会被移走，所以回滚完成后可以直接重新安装。
只有文件和服务状态都恢复成功时才会显示“回滚完成”。若提示自动恢复不完整，
请保留状态文件和 root-only 备份，先按错误中列出的具体路径人工核对，不要删除
session 或用外部文件覆盖受管路径后强行重试。
