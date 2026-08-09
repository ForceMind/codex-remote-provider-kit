# Codex Remote 第三方模型迁移套件

这套脚本用于在 Linux/systemd 服务器上，让 Codex Remote 的**模型推理**走
兼容 OpenAI Responses API 的第三方接口，同时保留手机 Remote 所需的官方
ChatGPT 登录与连接通道。

> 重要：这不是“完全绕过官方账户”。远控配对、登录和消息传输仍依赖官方
> 服务；提示词、代码、工具定义和工具结果则可能发送到第三方模型供应商。

## 仓库内容

- `install.sh`：安装第三方 provider、专用 systemd 服务和安全的密钥文件。
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
填写第三方 Base URL、模型、Provider ID 和推理强度，直接回车使用默认值。需要
系统权限时脚本会自动通过 `sudo` 重新执行，不需要手工拼接命令。

首次安装完成后会注册全局命令，以后在任意目录直接运行：

```bash
codex-rp
```

安装创建的 `codex-remote-provider.service` 会立即启动并设置为开机自启。退出命令
面板不会停止 Remote 后台服务；只有切换、停止或回滚操作才会改变服务状态。

## 新服务器一键安装并运行

前提：Linux/systemd、Bash、curl、Python 3，以及支持
`codex remote-control start` 的 Codex CLI。先在目标服务器完成 ChatGPT 登录。

```bash
gh repo clone ForceMind/codex-remote-provider-kit
cd codex-remote-provider-kit
sudo ./setup.sh install
```

`setup.sh install` 会安全地提示输入第三方 API 密钥，然后自动安装、启动服务，并完成
模型目录、Responses 流式接口和真实 Codex 回合三层检查。密钥输入不会回显。
安装器还会把用户级默认 `model_provider`、`model` 和推理强度作为一组设置为
第三方配置；托管 Remote daemon 在创建新会话时会读取这些值。

已经安装过时，再次运行 `sudo ./setup.sh` 不会覆盖备份或配置，只会重新启动
第三方 Remote 并执行完整检查。

如需覆盖默认参数：

```bash
sudo ./setup.sh install --model gpt-5.5 --reasoning medium
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

新会话的服务器端 `session_meta.model_provider` 应为 `inno_flare`，模型也应与
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

- [Codex 配置参考](https://learn.chatgpt.com/docs/config-file/config-reference)
- [Remote connections](https://learn.chatgpt.com/docs/remote-connections)
