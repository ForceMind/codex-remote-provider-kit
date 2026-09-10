# 变更记录

本项目遵循语义化版本。版本号的唯一来源是仓库根目录的 `VERSION` 文件；Git 标签和
GitHub Release 使用对应的 `v<version>` 名称。

## 1.0.0 - 2026-08-12

首个稳定版本，覆盖 Linux/systemd、macOS 和 Windows 的第三方 provider 管理流程。

### 新增

- Linux 双 systemd unit，显式切换第三方与官方 Remote，并跨重启保留选择。
- macOS Keychain、Windows 当前用户 DPAPI 凭据存储，以及桌面 Remote 配置切换。
- Linux/macOS 受管安装的启动时安全自动更新，支持失败开放和单次跳过。
- 中文命令面板、状态检查、真实最小调用测试、重新配置、密钥轮换和完整回滚。

### 稳定性与安全

- 目标 unit 启动失败时检查真实 systemd 状态并恢复切换前配置和服务模式。
- Codex Remote 连接进入 errored 状态时，有界停止残留 daemon，并重试同一模式一次。
- Remote `ExecStop` 设置 30 秒上限，避免异常连接长期阻塞切换。
- 第三方密钥不会写入仓库、命令行参数、普通配置或状态文件。
- 自动更新只替换带受管源标识的程序目录，不修改密钥、provider 选择或 Remote 服务。
