# 架构与数据流

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

Remote 的托管 app-server 是独立后台进程。安装器会同时设置用户级顶层
`model_provider`、`model` 和 `model_reasoning_effort`，因为启动命令上的临时覆盖
不一定被托管 daemon 继承。人工切回官方时从安装前备份恢复这三项（原来不存在
的项会被移除），再停止并重新启动 daemon，避免把第三方模型名带到官方 provider。

macOS/Windows 不依赖 shell 环境变量给桌面应用传密钥。它们使用 Codex 官方配置
支持的 `[model_providers.<id>.auth]`：认证命令只向 Codex stdout 返回令牌。该方式
不能和 `env_key`、直接 bearer token 或 OpenAI auth 同时配置，所以不同平台会生成
互斥的认证字段。

## systemd 设计

新的 Linux/systemd 服务器使用两个互斥的 unit：

- `codex-remote-provider.service` 加载 root-only 密钥并使用第三方三项默认配置；
- `codex-remote-official.service` 不加载第三方密钥，使用安装前默认配置；
- 两者都通过 `ExecStart` 调用 `remote-control start`，通过 `ExecStop` 调用 `stop`；
- `ExecStop` 有 30 秒上限，避免 errored 连接无限阻塞 systemd 切换；
- 切换时只启用一个 unit，因此最后一次人工选择会跨重启保持；
- 安装前两个同名 unit 和旧 `codex.service` 的状态都会记录，回滚时恢复。

当前 Remote CLI 会自行派生后台 daemon，因此 unit 使用 `Type=oneshot` 和
`RemainAfterExit=yes`。这能让 systemd 管理启动、停止和开机模式，却不能让它直接
监督 daemon 的实际 PID；daemon 在 unit 显示 active/exited 后异常退出时，仍需
通过 `status.sh` 或外部监控发现。这是现阶段明确保留的限制。

## 回退设计

回退是显式的，不是自动的：第三方故障时由管理员运行 `use-official.sh`，阅读
额度警告并输入 `y` 确认。这样不会因为一次短暂超时就悄悄消耗官方额度。切换过程
会保存当前用户配置和两个 unit 的启用/运行状态；目标模式启动异常时会先清理残留
daemon，并有界重试同一模式一次，仍失败才尝试恢复。这不会选择另一个 provider，
因此不构成自动故障转移。

## 安装与回滚事务

安装器先生成并验证配置、profile、密钥文件、两个 unit、launcher 和状态文件的
临时版本，再替换目标文件并启动服务。若替换后任一步失败，错误处理会尝试恢复
原配置、原 unit、原 launcher 及原服务启用/运行状态；只有第三方服务成功启动后
才写入活动 `state.env`。

完整回滚采用所有权保护的选择性撤销：只移除本工具带标记的 provider、profile、
unit 和 launcher，仅在顶层三项仍属于本工具或官方快照时恢复默认值，并保留安装后
新增的其他 provider 和无关配置。残缺 marker、同名 provider 或被修改的受管对象会
在停止服务和删除凭据前阻断。凭据成功删除后才把不含密钥的活动状态移入 `audit/`；
删除失败会保留状态以便重试。三端均不删除登录缓存、配对或 session。

桌面平台日常官方/第三方切换和 `reconfigure` 只修改本工具拥有的配置。三项默认值
先在同目录临时文件中组合完成，再一次替换正式配置，避免部分写入；桌面端不会因
重新配置而自动重启 ChatGPT。

macOS 和 Windows 都把配置状态分为官方、本工具第三方和外部管理；检测到 CC Switch
等工具选择外部 provider 时，写操作停止而不是争抢顶层默认值。回滚按字段和带标记
区块撤销本工具修改，保留其他 provider。同名 provider 或专用 profile 被外部修改时
拒绝猜测所有权。由于工具之间不共享锁，仍必须遵循单一写入者原则，不能同时切换。

Windows 在线安装还分别保护程序目录、全局启动器和用户 PATH：启动器已有但缺少
套件标记时直接拒绝覆盖；升级后续步骤失败时恢复旧目录、旧启动器和原 PATH。

Linux/macOS 在线安装会在程序目录写入不含凭据的源归档标识。全局启动器和
macOS `.app` 只在这个标识存在时运行自动更新，因此不会替换 Git 工作区或手工解压
目录。当前默认 `development` 以兼容 `main` 在线入口；development 清单存在时验证
SHA-256，清单尚未发布时明确警告并使用 GitHub HTTPS 的 main 归档。固定 Release
制品可明确使用 `stable`，且 stable 不回退跟踪 `main`。随后复用在线安装器的备份/
替换事务。失败时启动器继续执行当前版本，更新过程不会读取密钥、修改 Codex 配置、
切换 provider 或重启 Remote。清单和归档仍共享 GitHub 信任边界，SHA-256 不等同于
独立签名。

## macOS 快捷启动边界

macOS 会在当前用户的 `~/Applications` 安装一个最小 `.app` bundle。Bundle 中只包含
`Info.plist`、受管标记、本地 `.icns` 图标和两层启动脚本：第一层请 macOS 用
Terminal 打开内置 `.command`，第二层执行已安装的 `codex-rp menu`。Bundle 不包含
provider 配置、密钥、ChatGPT 登录数据或会话数据，也不在后台常驻。

同名 `.app` 只有在包内受管标记完全匹配时才会被刷新。安装事务会记录安装前是否已有
受管 bundle；后续失败或完整回滚时恢复原 bundle，否则只移除本次创建的入口。
用户或其他应用创建的同名目录、符号链接和无标记 bundle 都不会被覆盖。
