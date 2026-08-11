# Codex Remote 第三方供应商工具完整需求

本文档是本仓库的产品需求、实现边界和验收清单。文中的“必须”是发布阻断项，
“应”是推荐实现；若实现与本文档冲突，应先更新需求和相应测试，不能只修改代码。

## 1. 产品目标与成功标准

- 必须提供一个可安装、可升级、可检查、可切换、可回滚的完整工具，让 Codex 的
  模型推理可以使用兼容 OpenAI Responses API 的第三方网关。
- 必须继续使用官方 ChatGPT/Codex 账户完成登录、workspace、设备配对和 Remote
  消息通道；第三方供应商只承接模型推理，不替代官方 Remote 服务。
- 必须明确提示：提示词、代码、工具定义、工具结果和模型输出可能发送给第三方。
- Linux 中已使用稳定 Provider ID 的 thread，在官方与第三方推理之间切换后必须先
  尝试继续；不可见时按 thread ID 显式恢复，只有恢复失败时才新建会话。
- 必须避免自动切换到可能产生费用的官方模型；所有官方/第三方切换均由用户发起。
- 必须在失败时恢复到操作前状态，不能留下“配置已切换但服务未切换”或不完整的
  Provider 注册记录。

验收标准：从全新系统完成安装后，管理员可通过 `codex-rp` 完成状态检查、真实
调用、供应商管理、人工切换、密钥轮换和完整回滚；Linux 稳定 ID 下的会话在后端
切换后仍可显式列出和恢复。

## 2. 支持范围与运行边界

- 必须支持使用 systemd、具备 root/sudo 权限的 Linux Remote 宿主。
- 必须支持 macOS ChatGPT 桌面应用和 Windows 原生 ChatGPT 桌面应用。
- Windows PowerShell 实现必须兼容 Windows PowerShell 5.1 和 PowerShell 7。
- WSL2 默认视为独立 Codex 环境；不得宣称它自动共享 Windows 的配置、认证或会话。
- Linux 管理脚本必须使用 Bash；所有 Shell 脚本必须通过 `bash -n`。
- 第三方接口必须兼容 `/v1/models` 和流式 `/v1/responses`；仅模型列表可访问不能
  视为完整兼容。
- 本工具不得创建自有公网 Remote 服务、替换官方登录或修改官方设备配对协议。

## 3. 双通道路由与信任边界

- 官方通道必须负责：ChatGPT 登录、账号/workspace、设备配对、安全中继和 Remote
  消息传输。
- 推理通道必须可选择：官方 Codex endpoint，或用户配置的第三方 Responses endpoint。
- 配置第三方后，不得把第三方 API Key 当作 ChatGPT 登录凭据；两种凭据必须独立。
- 状态和文档必须能让用户区分“Remote 已连接”和“第三方模型接口可用”这两个状态。
- 工具只配置 Codex 支持的 user-level Provider，不得把关键 Provider 配置写到项目级
  `.codex/config.toml`。

## 4. Linux 稳定会话身份与连续性

- 必须区分两个 ID：
  - `PROVIDER_ID`：某个具体第三方地址的注册记录 ID；
  - `SESSION_PROVIDER_ID`：写入 Remote thread 元数据的稳定会话身份。
- 新安装时，`SESSION_PROVIDER_ID` 必须固定为初始 `PROVIDER_ID`。
- 旧版本首次升级且没有稳定 ID 时，必须把升级当时的 `PROVIDER_ID` 固定为
  `SESSION_PROVIDER_ID`；以后不得因切换地址、模型或模式而改变。
- user-level `model_provider` 和两个 systemd unit 的启动参数必须始终使用
  `SESSION_PROVIDER_ID`。
- 第三方模式必须把稳定 Provider block 绑定到所选 Base URL，使用该供应商的
  `env_key`，并移除官方认证字段。
- 官方模式必须把同一个稳定 Provider block 绑定到
  `https://chatgpt.com/backend-api/codex`，设置 `requires_openai_auth = true`，并移除
  `env_key`、直接 Bearer token 和命令式第三方认证字段。
- 切换前必须提示等待当前 turn 和工具调用结束；切换会重启 Remote daemon，并允许
  短暂断线。若原 thread 已使用稳定 ID，重连后应先尝试继续；不可见时按 thread ID
  显式恢复，不得把本地路由测试等同于真实手机端到端保证。
- 同一 thread 同时只能有一个活跃写入者；稳定 ID 不得被宣传为可以消除
  `thread-store conflict`。

验收标准：自动化测试必须以同一个 `SESSION_PROVIDER_ID` 在 endpoint A 创建 thread，
切到 endpoint B 后仍能通过 Provider 过滤列出该 thread、恢复相同 thread ID，并让
下一 turn 同时包含切换前历史和新输入；磁盘上只能保留同一个 rollout。

## 5. 历史会话兼容与恢复边界

- 不得删除、复制、批量改写或伪造 Codex 的 SQLite、JSONL、rollout 或 session 文件。
- 必须说明切换后历史“消失”的常见原因：旧 thread 元数据仍记录 `openai` 或旧
  Provider ID，而客户端可能按当前 Provider 过滤；这不等于记录已删除。
- 升级后在稳定 ID 下创建或继续的 Linux thread，切换后应先尝试直接续写；客户端
  不可见时仍须按 thread ID 显式恢复。
- 升级前的旧 thread 在已知 thread ID 时，应提供显式 `codex resume` 加模型和
  Provider 覆盖的人工恢复方法。
- 必须要求恢复前停止其他写入者；显式恢复失败后才建议创建新会话。
- 不得宣称存在官方批量迁移 API，也不得把 Linux 的稳定 ID 机制描述成 OpenAI
  客户端原生的跨 Provider 迁移能力。
- macOS/Windows 当前未实现稳定 ID 重绑定；应用重启后应新建会话，不能承诺无缝续写。

## 6. Linux 多第三方供应商注册表

- Linux 必须允许保存多个第三方 Base URL，并能列出、选择和切换已有记录；本节
  不适用于当前只管理单个第三方地址的 macOS/Windows 实现。
- 标准安装、面板和重新配置流程中的 `PROVIDER_ID` 必须由规范化 Base URL 确定性
  生成：相同地址（含可忽略的尾斜杠）得到相同 ID，不同 host、port 或 path 得到
  不同 ID。只有直接调用底层安装器时，才可通过显式 `--provider-id` 保留旧版手工
  ID 或支持隔离测试；该高级兼容入口不得用于新增生产地址。
- ID 必须只包含 Codex 配置和文件名可安全使用的字符，并包含短哈希以降低碰撞风险。
- 每个 Provider 必须保存独立的元数据、profile 和密钥文件；新增地址不得覆盖旧地址。
- 状态文件必须保存带版本的所有权清单，逐项列出套件管理的 Provider ID、目录来源和
  profile 标记策略；切换、状态检查与回滚只能遍历该清单，不得扫描并接管目录中的
  其他 `.env` 或 profile。
- 选择已有 Provider 时不得要求重新输入 URL、模型或密钥。
- 保存同一 URL 时应更新原记录；旧版手工 Provider ID 应安全升级为地址派生 ID，
  且只有新记录完整提交后才清理旧记录。
- 注册元数据损坏、密钥缺失或密钥格式无效时必须拒绝切换并保持原模式。

Linux 默认存储：

```text
/var/lib/codex-remote-provider/state.env
/var/lib/codex-remote-provider/providers/<PROVIDER_ID>.env
/etc/codex-remote-provider/provider.env
/etc/codex-remote-provider/providers/<PROVIDER_ID>.env
$CODEX_HOME/<PROVIDER_ID>.config.toml
```

## 7. Linux 安装、依赖与升级

- `setup.sh` 必须保持为安全的一键入口，支持菜单和非菜单子命令。
- 从零安装必须依次完成：依赖检查、Codex CLI 检查/安装、ChatGPT 设备登录、第三方
  参数输入、静默密钥输入、Provider 安装、服务启动和完整验证。
- Linux 自动依赖安装应支持 `apt-get`、`dnf` 和 `yum`；其他发行版必须给出明确提示。
- 缺少兼容 Codex CLI 时，必须调用 OpenAI 官方安装入口，不能在仓库内捆绑未知二进制。
- Remote 必须验证 `codex login status` 为 ChatGPT 登录；API Key 登录不能冒充
  Remote 所需的 ChatGPT 登录。
- API Key 交互输入不得回显内容；可以只显示字符数和“内容已隐藏”。
- 重复运行安装必须识别已有状态，不覆盖初始备份，不无故要求重新输入密钥。
- 升级必须刷新受管 systemd unit 和全局 launcher，同时保留当前 Provider 注册表、
  稳定会话 ID、密钥和可回滚状态。
- 安装完成前不得写入成功状态；真实启动失败时必须回滚本次文件和服务变更。

## 8. Linux systemd 与人工模式切换

- 必须创建两个互斥 unit：
  - `codex-remote-provider.service`：加载 root-only 第三方 `EnvironmentFile`；
  - `codex-remote-official.service`：不加载第三方密钥，使用官方认证。
- 任意时刻最多只能有一个 unit active/enabled；冲突时状态检查和切换必须失败。
- 最后一次人工选择必须写入 systemd enable 状态并在系统重启后保持。
- 切换必须完整停止旧 daemon，再启动目标模式，不能依赖临时 shell 环境覆盖。
- 第三方切官方前必须显示可能消耗官方额度的警告并要求确认。
- 第三方接口故障不得触发自动故障转移；恢复第三方也必须由用户明确执行。
- unit、launcher 或目标服务启动失败时，必须恢复切换前配置、文件和两个服务的
  enabled/active 状态。
- 文档必须说明当前 `Type=oneshot`/`RemainAfterExit=yes` 只能管理启动模式，不能直接
  监督 Codex 派生 daemon 的实际 PID。

## 9. 配置修改、密钥轮换与命令界面

- Linux 统一命令至少必须支持：`menu`、`install`、`codex`、`status`、`test`、
  `official`、`third-party`、`reconfigure`、`rotate-key`、`rollback`。
- `reconfigure` 必须支持新增地址、更新当前/已有地址的模型与推理强度，并保留当前
  官方/第三方模式。
- `rotate-key` 必须只更新当前 Provider 的密钥，不修改地址、模型或推理强度；非当前
  Provider 必须通过 `reconfigure` 选择或更新。
- 第三方正在运行时，配置成功后必须重启并执行完整检查；官方模式下只保存第三方
  配置，等用户切回时生效。
- user-level `model_provider`、`model`、`model_reasoning_effort` 必须与当前 Remote 模式
  保持同步。
- 全局 `codex-rp` launcher 必须带受管标记；同名非受管文件存在时必须拒绝覆盖。
- 菜单、帮助、进度和可操作错误应使用中文；systemd、Codex 和上游接口的原始字段
  可保留英文以便检索。

## 10. 状态检查、真实验证与诊断

- 基础 `status` 必须是只读检查，不生成模型回复。
- 必须检查：状态文件、配置、当前模式、稳定/具体 Provider ID、密钥文件存在性与
  权限、unit 互斥状态、Remote 进程/连接所需条件。
- 第三方完整 `test`/`status --full` 必须分层验证：
  1. `/v1/models` 鉴权和模型目录；
  2. `/v1/responses` 数组 `input`、`stream=true` 和完成事件；
  3. 临时 `codex exec` 的真实模型回合。
- `/v1/models` 成功但 Responses 或 Codex 回合失败时，必须报告完整检查失败。
- 官方模式的 `--full` 默认不得生成模型回复，以免意外消耗官方额度。
- 诊断输出不得显示密钥、Authorization header、完整环境、真实 session 正文或
  未脱敏业务内容。
- 故障排查必须覆盖：登录误判、Provider 配置未被 daemon 继承、历史被过滤、
  active writer 冲突、401/403、429/超时/5xx、Responses 格式错误、systemd 203/EXEC、
  残留 daemon、Windows/WSL 配置差异。

## 11. 事务、原子写入与失败恢复

- 安装、切换、注册表同步、重新配置、密钥轮换、unit/launcher 刷新和旧 ID 清理必须
  处于明确的事务边界内。
- 任何持久化写入前必须先完成快照；清理 trap 必须在可能复制密钥的临时操作前安装。
- 快照尚未完成时失败，只能清理临时目录，不能用不完整快照覆盖正式文件。
- 被 `if`、`!`、`||` 等 Bash 条件上下文调用的写函数必须显式传播每一步错误，不能
  依赖 `set -e`，避免中间写失败后被后续成功命令掩盖。
- 新生成的配置、状态、Provider record、密钥、profile、unit 和 launcher 必须先在
  临时位置完成格式验证；可行时使用同目录原子替换，否则必须由高层快照事务保证
  失败恢复。含密钥临时文件必须使用最小权限并在成功或失败后清理。
- 回滚必须恢复操作前 state、活动密钥、注册 record/secret、profile、配置、两个
  unit、官方 unit 备份、launcher 和服务选择。
- 只有所有写入、服务操作和必要验证成功后才能设置事务 committed；旧 Provider ID
  的文件清理也必须发生在错误 trap 仍有效时。
- 恢复本身失败时必须明确报告，不能把操作标记为成功。

## 12. 完整回滚与审计

- `rollback` 必须要求明确确认，停止两个受管 Remote 模式，并恢复安装前配置。
- 必须恢复安装前已有的同名 unit、launcher 和旧 `codex.service` enabled/active 状态。
- 必须删除套件持久化的所有第三方活动密钥和各 Provider 密钥。
- 必须移除套件管理的 Provider blocks、profiles、unit 和 launcher，但不得删除或覆盖
  无受管标记的用户文件。
- 回滚删除任何清单路径前必须重新验证 record、secret、profile 及受管标记；路径为
  符号链接，或类型、标记、字段关系、密钥副本等校验不匹配时必须停止并保留该路径。
  没有所有权 schema 的旧状态不得扫描或删除 Provider 注册表目录，只能处理旧状态
  明确记录的安装资源。
- 不得删除 ChatGPT 登录缓存、设备配对、Codex session 或用户无关配置。
- 不含密钥的 `state.env` 应移动到权限受限的 `audit/` 目录；活动状态移走后必须允许
  直接重新安装。

## 13. macOS 桌面平台

- 必须以实际登录 ChatGPT 的普通桌面用户运行，不得要求 root。
- 当前一次安装只管理一个用户指定的第三方 Provider ID，不得宣称支持 Linux 注册表
  的多地址选择和地址派生 ID。
- `official` 只是兼容命令名，必须恢复安装前记录的默认值；工具不得声称已验证这些
  原始值一定属于 OpenAI Provider，状态必须将该模式标为 `baseline`。
- 第三方密钥必须保存到 macOS Keychain；TOML 只能保存受控 `auth.command`，不得
  写入明文 token。
- 安装和切换必须原子更新 user-level 三项默认配置，并保留其他用户配置。
- `official`、`third-party` 命令不得自动退出或重启 ChatGPT 应用。
- `restart-app` 必须单独提供、要求明确确认，并说明 Remote 会短暂断线但不会注销或
  删除配对。
- `status` 必须检查配置和 Keychain 项；`test` 只允许在第三方模式执行。
- `rollback` 必须恢复原配置并删除对应 Keychain 项，不删除 session 或在线安装器
  管理的 launcher；launcher 的升级失败恢复属于在线安装器事务。
- 桌面平台当前必须提示重启应用后从手机新建会话，不得宣称 Linux 式稳定 ID 续写。

## 14. Windows 原生桌面平台

- 必须以实际登录 ChatGPT 的当前 Windows 用户运行；不得让另一管理员用户代为安装。
- 当前一次安装只管理一个用户指定的第三方 Provider ID，不得宣称支持 Linux 注册表
  的多地址选择和地址派生 ID。
- `official` 只是兼容命令名，必须恢复安装前记录的默认值；工具不得声称已验证这些
  原始值一定属于 OpenAI Provider，状态必须将该模式标为 `baseline`。
- 第三方密钥必须使用当前用户 DPAPI 加密；TOML 只能引用受控解密助手和密文路径。
- DPAPI 密文不得被另一用户复制后继续使用；状态检查必须识别“当前用户无法解密”。
- 安装和切换必须原子更新 user-level 三项默认配置，并保留其他用户配置。
- 在线安装器必须事务保护程序目录、`.cmd`/PowerShell launcher 和用户 PATH；升级
  失败时恢复旧版本和原 PATH。
- 已有同名非受管 launcher 时必须拒绝覆盖。
- `restart-app` 必须显式确认；切换不得自动重启、注销或删除配对。
- `rollback` 必须删除 DPAPI 密文、恢复原配置并保留无密钥审计状态；它不卸载在线
  安装器管理的程序、launcher 或 PATH。在线安装升级失败时才恢复这些安装器资源。
- 中文 PowerShell 文件必须保持 Windows PowerShell 5.1 可解析的编码和语法。

## 15. 安全与隐私要求

- 默认值、示例、测试 fixture、日志、文档、Issue 和 Git 历史不得包含真实凭据。
- 不得把 API Key 放入命令行参数、进程标题、`config.toml`、systemd manager 全局
  环境或普通日志。
- Linux 密钥目录必须为 `0700`，密钥和状态文件必须为 `0600`；密钥读取必须按严格
  单行变量格式解析，不能把不可信密钥文件当脚本执行。
- 调用 curl 时，Authorization header 必须通过权限受限的临时配置传递，避免出现在
  命令行；临时文件必须清理。
- 第三方 Base URL 默认必须使用 HTTPS，并拒绝凭据、query、fragment、空白、引号和
  反斜杠等危险形式。
- 只有隔离的本机测试才可通过命令行显式允许 HTTP；面板不得默认放宽。
- 必须校验 Provider ID、环境变量名、模型名、推理强度和 API Key 字符集。
- API Key 泄露指引必须要求立即吊销/轮换；仅删除文件或改成私有仓库不算完成处置。
- GitHub CI 必须扫描常见凭据模式；提交前仍必须人工检查 staged diff。

## 16. 测试、文档、交付物与非目标

发布前必须完成以下验收：

- 全仓库所有 `*.sh` 通过 `bash -n`。
- 13 个 Shell 回归测试全部通过，覆盖配置、launcher、登录识别、密钥校验、unit、
  安装事务、切换/回滚、重新配置/轮换、多 Provider、旧版升级和会话连续性。
- Linux 事务测试必须注入写入、启动、完整状态检查和旧记录清理失败，并验证所有
  受管文件与服务选择恢复。
- Windows 脚本通过 Windows PowerShell 5.1 与 PowerShell 7 语法检查，平台生命周期
  和在线安装器测试通过。
- macOS 配置、Keychain 命令、切换、重启确认和回滚生命周期测试通过。
- `git diff --check`、冲突标记、尾随空白和凭据扫描通过。
- README 必须提供安装和常用命令；`docs/ARCHITECTURE.md`、
  `docs/OPERATIONS.md`、`docs/TROUBLESHOOTING.md`、`SECURITY.md` 必须分别覆盖架构、
  运维、排障和安全边界。
- GitHub Actions 必须在 push 和 pull request 上运行 Linux 与 Windows 验证。

明确不属于本项目目标：

- 自动故障转移或自动使用官方付费额度；
- 绕过 ChatGPT 登录、workspace、Remote 配对或官方消息通道；
- 托管一个新的公网代理、保存用户会话或实现自定义移动端；
- 修改/迁移 Codex 内部数据库与 JSONL，或承诺恢复所有旧 Provider 历史；
- 承诺任意“OpenAI 兼容”网关都完整兼容 Codex 工具调用；
- 在 macOS/Windows 上承诺切换 Provider 后无缝续写旧会话；
- 在未经真实设备验证时宣称桌面 Remote 已生产可用。

完成定义：代码、测试和上述文档一致；本地验证全部通过；提交中不含凭据或真实
会话数据；通过独立分支和 Draft PR 交付，未经用户明确要求不得自动合并。
