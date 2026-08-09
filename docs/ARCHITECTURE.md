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

## systemd 设计

新服务器使用独立的 `codex-remote-provider.service`：

- `Type=oneshot` 与 Remote CLI 的后台 daemon 行为匹配；
- `ExecStart` 调用 `remote-control start`，`ExecStop` 调用 `stop`；
- 密钥只通过权限为 0600 的 `EnvironmentFile` 注入；
- 安装前的旧 `codex.service` 状态会记录，回滚时恢复。

## 回退设计

回退是显式的，不是自动的：第三方故障时由管理员运行 `use-official.sh`，阅读
额度警告并输入确认词。这样不会因为一次短暂超时就悄悄消耗官方额度。
