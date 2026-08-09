# 故障排查

先运行：

```bash
sudo ./status.sh
sudo systemctl status codex-remote-provider.service --no-pager
```

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
model_provider = "inno_flare"
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

## `429`、超时或 `5xx`

这是配额、限流或上游故障。先间隔重试并查看供应商状态；业务必须继续时，人工
执行 `use-official.sh`。恢复后再 `use-third-party.sh` 并运行完整检查。

## 回退也无法恢复

运行 `rollback.sh` 恢复安装前状态，并查看备份目录。若要提交 Issue，请使用
仓库模板，仅附脱敏后的版本号、HTTP 状态、时间和最少日志。
