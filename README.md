# Codex Remote 第三方模型迁移套件

这套脚本用于在 Linux/systemd 服务器上，让 Codex Remote 的**模型推理**走
兼容 OpenAI Responses API 的第三方接口，同时保留手机 Remote 所需的官方
ChatGPT 登录与连接通道。

> 重要：这不是“完全绕过官方账户”。远控配对、登录和消息传输仍依赖官方
> 服务；提示词、代码、工具定义和工具结果则可能发送到第三方模型供应商。

## 仓库内容

- `install.sh`：供 `curl | sh` 使用的公开在线安装入口。
- `install-provider.sh`：安装第三方 provider、专用 systemd 服务和安全的密钥文件。
- `install-codex.sh`：检查系统依赖，安装 Codex CLI 并引导 ChatGPT 登录。
- `setup.sh`：一键安装、启动、完整验证，以及统一管理入口。
- `status.sh`：分层检查服务、配置、模型接口和真实 Codex 调用。
- `use-official.sh`：人工切回默认/官方推理，可能消耗官方额度。
- `use-third-party.sh`：人工切回第三方推理。
- `rollback.sh`：恢复安装前配置并移除持久化密钥。
- `docs/OPERATIONS.md`：日常启动、切换、升级和密钥轮换手册。
- `docs/TROUBLESHOOTING.md`：按症状排查手机报错、接口错误和进程冲突。
- `docs/ARCHITECTURE.md`：数据流、边界和回退机制。
- `MIGRATION_PROMPT.md`：复制到其他服务器后可直接交给 Codex 的迁移提示词。
- `current-host/`：仅用于最初已经配置过的源服务器，不用于新服务器安装。

## 安全边界

不要把 API 密钥写进仓库、聊天、命令行参数或 `config.toml`。安装器会把密钥
写入 `/etc/codex-remote-provider/provider.env`，权限为 root-only。请只使用可信
供应商，并假设第三方能够看到模型调用中发送的内容。

如果密钥曾经发到聊天、日志、终端截图或工单中，应立即在供应商后台吊销并
生成新密钥。私有仓库也不能替代密钥轮换。

## 一键命令面板

克隆仓库后直接运行：

```bash
./panel.sh
```

面板统一提供安装、状态检查、完整测试、第三方/官方切换和回滚。首次安装可以
填写第三方 Base URL、模型、Provider ID 和推理强度；Base URL 必须替换为真实
地址，其他项目可直接回车使用默认值。需要系统权限时脚本会自动通过 `sudo`
重新执行，不需要手工拼接命令。
套件自身的菜单、帮助、进度和错误提示均使用中文；systemd、Codex CLI 与第三方
接口直接返回的字段或日志会保留原文，便于检索和排障。

首次安装完成后会注册全局命令，以后在任意目录直接运行：

```bash
codex-rp
```

从旧版本升级时，在仓库中运行一次新版 `./panel.sh` 即可补装该命令，不需要回滚、
重新安装或重新输入 API 密钥。

安装创建的 `codex-remote-provider.service` 会立即启动并设置为开机自启。退出命令
面板不会停止 Remote 后台服务；只有切换、停止或回滚操作才会改变服务状态。

## 新服务器从零安装并运行

前提：使用 systemd 的 Linux 服务器、root/sudo 权限，以及一枚第三方供应商 API
密钥。套件会检查 `curl` 和 Python 3；缺少时会通过 `apt-get`、`dnf` 或 `yum`
安装。若没有兼容的 Codex CLI，则调用 OpenAI 官方独立安装器。

仓库公开后，推荐直接运行在线安装命令：

```bash
curl -fsSL https://raw.githubusercontent.com/ForceMind/codex-remote-provider-kit/main/install.sh | sh
```

该命令会把套件安装到 `/opt/codex-remote-provider-kit`，升级时先备份旧目录，
然后打开中文面板。若希望先审查脚本，可以先下载 `install.sh`，阅读后再执行。

推荐直接把本目录旁的压缩包复制到新机器，这样目标机不需要预装 Git：

```bash
scp codex-remote-provider-kit.tar.gz root@SERVER_IP:/root/
ssh root@SERVER_IP
tar -xzf /root/codex-remote-provider-kit.tar.gz
cd codex-remote-provider-kit
./panel.sh
```

如果目标机已经安装 Git，也可以直接克隆：

```bash
git clone https://github.com/ForceMind/codex-remote-provider-kit.git
cd codex-remote-provider-kit
./panel.sh
```

在菜单中选择 `1`。流程会依次执行：

1. 检查并安装系统依赖；
2. 检查 Codex CLI，缺少或不支持 Remote 时运行 OpenAI 官方安装器；
3. 显示网址和设备代码，引导完成 ChatGPT 登录；
4. 询问第三方 Base URL、模型和推理强度；
5. 静默读取第三方 API 密钥；
6. 安装并启动 Remote 服务，然后完成接口和真实 Codex 回合验证。

ChatGPT 登录和第三方 API 密钥是两个独立凭据：前者用于 Remote 配对及连接，
后者用于第三方模型推理。不要把任何密钥放到命令行、仓库或聊天中。

也可以不进入菜单，直接执行同样的完整流程：

```bash
sudo ./setup.sh install
```

直接运行时会要求输入真实的第三方 Base URL；示例地址不能用于安装。

仅安装/检查 Codex CLI 和 ChatGPT 登录：

```bash
sudo ./setup.sh codex
```

`setup.sh install` 会先准备 Codex，再安全地提示输入第三方 API 密钥，然后自动
安装、启动服务，并完成模型目录、Responses 流式接口和真实 Codex 回合三层检查。
密钥输入不会回显。
按回车后脚本会显示已接收的字符数，便于确认粘贴成功，但不会显示密钥内容。
安装器还会把用户级默认 `model_provider`、`model` 和推理强度作为一组设置为
第三方配置；托管 Remote daemon 在创建新会话时会读取这些值。

已经安装过时，再次运行 `sudo ./setup.sh` 不会覆盖备份或配置，只会重新启动
第三方 Remote 并执行完整检查。

如需覆盖默认参数：

以下 Base URL 仍是格式示例，实际执行时请替换为供应商提供的真实地址。

```bash
sudo ./setup.sh install \
  --base-url https://provider.example/v1 \
  --model gpt-5.5 \
  --reasoning medium
```

安装器会备份重叠配置、校验 TOML、保存原服务状态，并启动独立的
`codex-remote-provider.service`。

## 验证

统一管理入口：

```bash
sudo ./setup.sh status       # 基础检查，不生成模型回复
sudo ./setup.sh test         # 完整真实调用检查
sudo ./setup.sh official     # 人工切回官方推理
sudo ./setup.sh third-party  # 切回第三方推理
sudo ./setup.sh rollback     # 完整回滚
```

也可以直接调用底层脚本。先做不产生模型回复的基础检查：

```bash
sudo ./status.sh
```

再做完整检查（会产生极少量第三方模型用量）：

```bash
sudo ./status.sh --full
```

最后在手机上**新建会话**，发送 `Reply exactly OK`。不要让本地 Codex 与手机
同时打开同一个会话；会话存储只允许一个活跃写入者。

新会话的服务器端 `session_meta.model_provider` 应为安装时填写的供应商 ID，模型也应与
安装参数一致。让模型自己回答 provider 不能作为验证依据；应使用服务器元数据
或 `status.sh --full`。

## 回退与恢复

第三方不可用时，人工切到默认/官方推理：

```bash
sudo ./use-official.sh
```

脚本要求输入确认词，防止无意消耗官方额度。恢复第三方：

```bash
sudo ./use-third-party.sh
```

完全撤销本套配置：

```bash
sudo ./rollback.sh
```

本项目刻意不做自动故障转移，因为自动切到官方模型可能产生意外费用。完整
运行方式见 [日常运维](docs/OPERATIONS.md)，报错时见
[故障排查](docs/TROUBLESHOOTING.md)。

## 已知兼容性说明

- Responses 请求的 `input` 必须是数组，并启用 `stream=true`；Codex 的实际请求
  符合这个要求。
- 当前第三方 `/v1/models` 返回 OpenAI 列表格式，但 Codex Remote 的可选模型
  目录刷新可能期待另一个字段，因此日志里可能出现非致命刷新错误。显式配置
  的模型仍可正常调用。
- Codex CLI/Remote 属于会更新的软件。升级后先执行 `status.sh --full`，再让手机
  承担正式工作。

## 官方参考

- [Codex CLI](https://developers.openai.com/codex/cli/)
- [Codex 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Remote connections](https://learn.chatgpt.com/docs/remote-connections)
