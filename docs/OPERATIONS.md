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

macOS 另外安装 `~/Applications/Codex 远程模型服务工具.app`。可从 Finder、
Spotlight 或 Dock 启动，效果与在终端运行 `codex-rp` 相同。快捷入口只打开
管理面板，不自动重启 ChatGPT 或改变当前 provider。升级后可运行
`codex-rp shortcut` 手工刷新；完整回滚会恢复或移除该受管入口。
每次刷新都会从已安装套件的 `platform/macos/assets/codex-rp.icns` 复制图标，
不会在运行时下载资源。
刷新时会把旧的受管英文 `.app` 迁移为中文文件名，不会改动不受管的同名应用。

切换命令本身不重启应用，避免无提示中断 Remote。配置只保证影响新任务；不要让
手机和本地应用同时写入切换前仍活跃的同一会话。

Windows 必须以实际登录 ChatGPT 的普通桌面用户运行；DPAPI 密文不能由另一用户或
管理员账户代为解密。macOS 同样应使用实际桌面用户，以便 `auth.command` 访问正确
Keychain。三项默认配置在两个平台都作为一次事务更新。

## macOS 与 CC Switch 共存

本工具和 CC Switch 都会修改用户级 `~/.codex/config.toml`。安装前必须先在
CC Switch 中切换到 OpenAI 官方配置；本工具把“顶层 `model_provider` 未设置或等于
`openai`，且 Codex 使用 ChatGPT 登录”判定为可安装的官方状态。检测不通过时会在
读取第三方密钥前停止。

安装后遵循单一写入者原则，不要同时操作两个工具：

1. 要使用本工具切换第三方时，先在 CC Switch 中切回官方，再运行
   `codex-rp third-party`。
2. 如果 CC Switch 已选择其他 provider，本工具的切换、测试和回滚会拒绝覆盖，
   `status` 显示 `external/unmanaged`。
3. 回滚只删除本工具带标记的 provider 区块，并保留后来新增的其他 provider。
4. 如果 CC Switch 改写了本工具的同名 provider 或专用 profile，必须先处理命名冲突；
   本工具不会猜测所有权或自动删除。

每次从官方状态执行 `codex-rp third-party` 时，本工具都会保存当时最新的三项官方
默认值。因此 CC Switch 在安装后调整的官方模型或推理强度，会在下一次
`codex-rp official` 或回滚时恢复，而不是被安装时的旧快照覆盖。

配置写入使用同目录临时文件原子替换，但 CC Switch 不共享本工具的锁或状态，因此
不能安全地同时点击切换。最后一次完成写入的工具决定新任务使用哪个 provider。

## macOS 升级验收清单

发布或升级 macOS 工具时，按下面顺序验收，过程中不要提供或记录明文密钥：

1. 重新运行 README 中的 `main` 在线安装命令，确认已安装程序目录被刷新并打开中文
   面板。
2. 让 CC Switch 保持外部 provider，选择菜单 `1` 并输入 Base URL；确认脚本在读取
   密钥前拒绝安装，而且自动返回主菜单。
3. 在 CC Switch 切回 OpenAI 官方配置，再次选择 `1`；确认官方配置和 ChatGPT 登录
   预检通过，并要求输入 `OFFICIAL`。
4. 完成安装后选择 `2`，确认当前模式、三项顶层默认值、受管 provider 和 Keychain
   状态正确。
5. 选择 `7` 明确重启 ChatGPT，再选择 `3` 完成真实调用测试，并从手机创建新会话。
6. 确认 `~/Applications/Codex 远程模型服务工具.app` 名称和图标正确；Dock 仍缓存旧
   图标时，选择菜单 `9` 刷新后重新添加 Dock 入口。

当前 macOS 实现已经按这条流程完成真机验收。后续 Codex CLI、ChatGPT 桌面应用或
macOS 大版本变化后，应重新执行整套清单；自动化测试不能替代 Keychain 授权和手机
Remote 链路的真实设备验证。

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

在线安装的 Linux/macOS 启动器会在打开面板前自动检查 `main`。归档未变时
直接使用当前目录；出现新版时先备份旧程序目录，再事务替换。更新不会修改
密钥、用户级 Codex 配置或当前 Remote 模式；失败时继续使用本地版本。临时
需要跳过网络检查时，可以仅对当次命令设置：

```bash
CODEX_RP_SKIP_AUTO_UPDATE=1 codex-rp
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

第一次安装需要终端交互，不能在无人值守任务中把密钥直接写进命令行。若要
自动化部署，应由服务器的秘密管理系统预先注入 `THIRD_PARTY_API_KEY` 环境变量，
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

若当前处于官方模式，将上述 unit 名替换为
`codex-remote-official.service`；`sudo ./status.sh` 会直接显示当前模式。

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

切换脚本会刷新两个 unit、停止另一模式并修改开机启用状态。项目不执行自动
故障转移。若目标服务第一次启动失败或启动后状态异常，脚本会有界停止残留
daemon、清除目标 unit 的 failed 状态，并重试同一模式一次；第二次仍失败才尝试
恢复切换前的配置和服务模式。官方模式下运行 `status.sh --full` 也不会生成回复，
以免意外消耗额度。

## 从旧版本升级套件

已经含自动更新器的 Linux/macOS 安装只需运行 `codex-rp`。从更旧功能发布前的
旧版升级时，先重新运行一次公开在线安装命令，让受管目录和全局启动器获得
新逻辑。随后打开新版面板或运行：

```bash
sudo ./setup.sh install
```

检测到现有状态时，脚本不会重写初始备份或密钥，而是通过 `refresh-units.sh`
刷新官方/第三方 unit 和 `codex-rp`，然后切回第三方模式并验证。

第三方接口默认必须是 HTTPS。仅隔离的本机测试可通过命令行显式增加
`--allow-http`；面向公网或局域网网关都不应使用明文 HTTP 传输密钥。

## 密钥轮换

先在供应商后台生成新密钥，然后从面板选择“仅修改第三方 API Key”，或运行：

```bash
codex-rp rotate-key
```

如需同时修改接口地址、模型或推理强度，运行：

```bash
codex-rp reconfigure
```

脚本会保留当前官方/第三方模式；第三方正在运行时会重启并执行完整验证，官方
模式下只保存配置，等下次切回第三方时生效。也可以按传统方式手工轮换：

```bash
sudoedit /etc/codex-remote-provider/provider.env
sudo chmod 600 /etc/codex-remote-provider/provider.env
sudo systemctl restart codex-remote-provider.service
sudo ./status.sh --full
```

文件只保留一行 `<环境变量名>="<新密钥>"`，不要加 `export`、命令替换或其他
shell 语法。确认新密钥正常后立即吊销旧密钥。

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
状态。审计状态文件会移动到 `/var/lib/codex-remote-provider/audit/`，不含 API
密钥；活动状态文件会被移走，所以回滚完成后可以直接重新安装。
