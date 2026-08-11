# 架构与数据流

完整产品范围、平台边界和发布验收标准见
[功能需求清单](../REQUIREMENTS.md)。本文只说明实现结构和关键设计决策。

## 实际链路

```text
手机 Codex/ChatGPT
        │ 官方登录、配对、Remote 消息通道
        ▼
服务器 codex remote-control daemon
        │ 读取用户级 model_provider 配置和 root-only 密钥
        ▼
第三方 /v1/responses
        │ 模型推理结果
        └──────────────────────────────► 手机
```

macOS/Windows 使用官方桌面 Remote 宿主：

```text
手机 ChatGPT Remote
        │ 同一 ChatGPT 账号/workspace、官方设备配对与安全中继
        ▼
Mac/Windows ChatGPT 桌面应用中的 Codex app-server
        │ 用户级 config.toml + provider auth.command
        ├── macOS Keychain (/usr/bin/security)
        └── Windows 当前用户 DPAPI (受控 PowerShell 助手)
        ▼
第三方 /v1/responses
```

桌面脚本不创建自己的公网监听器，也不替换 ChatGPT 登录。Remote 的账号、workspace、
配对和消息通道仍完全由官方桌面应用管理；工具只改变新 Codex 任务读取的三项用户
默认配置和第三方 provider 定义。

模型列表检查走第三方 `/v1/models`。它只证明鉴权和模型目录端点可访问，不代表
Responses 请求、流式事件格式或 Codex 工具调用一定兼容，所以 `status.sh --full`
会分别验证三个层次。

## 为什么获取模型成功但调用失败

`GET /v1/models` 通常只有鉴权和简单 JSON 返回；`POST /v1/responses` 对请求体和
流式事件协议要求更严格。已验证的第三方接口要求：

- `input` 是数组，不能只传字符串；
- `stream` 为 `true`；
- SSE 最终包含完成事件；
- 模型名必须是该网关实际支持的名称。

因此模型列表成功不能当作完整可用性的证明。

## 配置层次

Provider 配置必须写到用户级 `$CODEX_HOME/config.toml`。项目级 `.codex/config.toml`
不能覆盖机器本地的 `model_provider`/`model_providers` 等关键项。安装器另外生成
一个 profile 文件，便于使用 `codex exec --profile <provider-id>` 独立验证。

Linux 把两个 ID 分开管理：

- `PROVIDER_ID` 是具体第三方注册记录；标准安装和管理流程根据规范化 Base URL 的
  主机、端口、路径和短哈希生成，同一地址稳定得到同一 ID，不同地址不会覆盖。
  底层安装器的显式 ID 覆盖只保留给旧版手工 ID 兼容和隔离测试。
- `SESSION_PROVIDER_ID` 是 Remote thread 使用的稳定会话身份。首次安装时固定为
  初始 `PROVIDER_ID`；旧版首次升级时固定为升级当时的当前 `PROVIDER_ID`，以后
  切换地址、模型或官方/第三方模式都不改变。

第三方注册元数据保存在
`/var/lib/codex-remote-provider/providers/<id>.env`，密钥保存在
`/etc/codex-remote-provider/providers/<id>.env`；两处目录和文件均仅 root 可读写。
兼容 systemd 的活动密钥文件仍为 `provider.env`，切换时以原子安装方式从所选地址
的密钥文件更新，并同步活动 `state.env`、用户默认配置和 Remote unit。

`state.env` 同时保存带版本的所有权清单：明确列出受管 Provider ID、两个注册表目录
是否由套件创建，以及 profile 是否必须带受管标记。脚本只按该清单访问精确路径，
不会用 glob 扫描或接管目录中的其他 `.env`/profile。state、record 和 secret 必须是
root 所有、权限 `0600` 的普通文件，并在任何 shell 解析前完成检查；Provider 目录
必须是非符号链接的 root-only `0700` 目录。

Remote 的托管 app-server 是独立后台进程。安装器会同时设置用户级顶层
`model_provider`、`model` 和 `model_reasoning_effort`，因为启动命令上的临时覆盖
不一定被托管 daemon 继承。顶层 `model_provider` 始终是 `SESSION_PROVIDER_ID`：

- 第三方模式将 `[model_providers.<SESSION_PROVIDER_ID>]` 指向当前网关，设置该网关
  的 `env_key`，并移除 `requires_openai_auth`。
- 官方模式将同一个自定义 ID 指向
  `https://chatgpt.com/backend-api/codex`，设置 `requires_openai_auth = true`，并移除
  `env_key`、bearer token 和命令式认证字段。

切回官方时只从安装前备份恢复模型与推理强度；会话 provider ID 不恢复成
`openai`。随后停止并重新启动 daemon，让稳定 ID 在新模式下重新绑定端点。

macOS/Windows 不依赖 shell 环境变量给桌面应用传密钥。它们使用 Codex 官方配置
支持的 `[model_providers.<id>.auth]`：认证命令只向 Codex stdout 返回令牌。该方式
不能和 `env_key`、直接 bearer token 或 OpenAI auth 同时配置，所以不同平台会生成
互斥的认证字段。两个桌面平台目前仍按旧语义直接切换顶层 provider，没有实现
Linux 的 `SESSION_PROVIDER_ID` 重绑定，不能据此宣称切换后可无缝继续原 thread。

## 会话连续性边界

升级后以稳定 ID 创建或继续的 Linux thread，在官方与第三方之间切换时仍看到同一
`model_provider`，因此重连后应先尝试继续原 thread。切换必须等当前 turn 完整结束；
停止并重启 daemon 会造成短暂断线。真实手机 Remote、官方认证或客户端过滤仍可能
让 thread 不可见，此时应按 thread ID 显式恢复。若切换时仍有活跃写入者，稳定 ID
也不能消除 `thread-store conflict`。

升级前已经以 `openai` 或其他 provider ID 创建的历史仍保留原元数据，客户端可能
按 provider 过滤而不显示。可以用显式 thread ID 加模型/provider 覆盖恢复单个
thread，但本项目不会篡改 Codex 的 SQLite 或 JSONL，也没有官方批量迁移 API。
[Codex 命令参考](https://learn.chatgpt.com/docs/developer-commands.md?surface=cli)说明
`resume` 支持显式会话 ID 和全局覆盖；
[Remote connections](https://learn.chatgpt.com/docs/remote-connections.md)说明 Remote
可以继续已有聊天。稳定 ID 的端点重绑定是本项目的 Linux 实现，不是桌面平台能力。

## systemd 设计

新的 Linux/systemd 服务器使用两个互斥的 unit：

- `codex-remote-provider.service` 加载 root-only 密钥，以稳定会话 ID 使用第三方配置；
- `codex-remote-official.service` 不加载第三方密钥，以同一稳定 ID 使用官方认证；
- 两者都通过 `ExecStart` 调用 `remote-control start`，通过 `ExecStop` 调用 `stop`；
- 切换时只启用一个 unit，因此最后一次人工选择会跨重启保持；
- 安装前两个同名 unit 和旧 `codex.service` 的状态都会记录，回滚时恢复。

当前 Remote CLI 会自行派生后台 daemon，因此 unit 使用 `Type=oneshot` 和
`RemainAfterExit=yes`。这能让 systemd 管理启动、停止和开机模式，却不能让它直接
监督 daemon 的实际 PID；daemon 在 unit 显示 active/exited 后异常退出时，仍需
通过 `status.sh` 或外部监控发现。这是现阶段明确保留的限制。

## 回退设计

回退是显式的，不是自动的：第三方故障时由管理员运行 `use-official.sh`，阅读
额度警告并输入 `y` 确认。这样不会因为一次短暂超时就悄悄消耗官方额度。切换过程
会保存当前用户配置和两个 unit 的启用/运行状态；目标模式启动失败时会尝试恢复。

## 安装与回滚事务

安装器先生成并验证配置、profile、密钥文件、两个 unit、launcher 和状态文件的
临时版本，再替换目标文件并启动服务。若替换后任一步失败，错误处理会尝试恢复
原配置、原 unit、原 launcher 及原服务启用/运行状态；只有第三方服务成功启动后
才写入活动 `state.env`。

完整回滚恢复安装前文件与服务状态，删除持久化第三方密钥，并把不含密钥的
`state.env` 移入 `audit/`。这样既保留审计依据，也不会阻止下一次安装。
删除前会再次验证所有权清单、record/secret/profile 内容和受管标记；若精确路径是
符号链接，或类型、标记、字段关系、密钥副本等校验不匹配，回滚会在修改前停止。
旧状态没有所有权 schema 时不会扫描 Provider 注册表目录，以免把后来出现的同名
文件误当成套件资产。

桌面平台也保留安装前完整配置和 profile，但日常官方/第三方切换只修改顶层
`model_provider`、`model`、`model_reasoning_effort`，不会覆盖用户安装后新增的其他
配置。三项默认值先在同目录临时文件中组合完成，再一次替换正式配置，避免只写入
其中一部分。macOS 回滚删除 Keychain 条目；Windows 回滚先删除 DPAPI 密文，再移动
不含密钥的审计状态。两端都不删除登录缓存、配对或 session。

Windows 在线安装还分别保护程序目录、全局启动器和用户 PATH：启动器已有但缺少
套件标记时直接拒绝覆盖；升级后续步骤失败时恢复旧目录、旧启动器和原 PATH。
