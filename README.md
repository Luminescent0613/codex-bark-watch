# Codex Bark Watch

把 Codex Desktop 的关键事件推送到 Bark，再同步到手机或手表。

目前主要支持 Windows 下的两类提醒：

- 任务完成提醒：通过 Codex 的 `notify` 配置触发，并在发送 Bark 后继续转发给原来的通知命令。
- 权限审核提醒：监听 Codex session JSONL 文件，一旦发现 `sandbox_permissions=require_escalated` 的命令调用，就发送 Bark。

如果你只想了解权限审核 watcher 的实现，请看 [docs/watcher.md](docs/watcher.md)。

## 为什么需要它

有些 Codex Desktop 环境里，权限审核相关 hook 不一定稳定触发。这个项目采用更直接的方案：

- 任务完成：包装 Codex 的 `notify` 命令。
- 权限审核：在本机监听 Codex session 日志。

这样就能在你离开电脑、低头看手机、或者等长任务生成代码时，通过 Bark 及时收到提醒。

## 环境要求

- Windows
- Codex Desktop
- Go 1.22 或更高版本
- 一个 Bark 兼容的 HTTP 推送接口

## 构建

```powershell
go build -o dist\codex-bark-watch.exe .\cmd\codex-bark-watch
```

## 配置 Bark

复制示例配置：

```powershell
Copy-Item .\config\bark.example.json .\config\bark.local.json
```

编辑 `config\bark.local.json`：

```json
{
  "baseUrl": "https://www.ggsuper.com.cn/push/api/v1/sendMsg3_New.php",
  "token": "replace-with-your-token",
  "method": "POST",
  "url": "",
  "issecure": 0,
  "sender": "Codex"
}
```

先测试 Bark 是否能收到：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-bark.ps1
```

## 配置提醒文案

复制示例配置：

```powershell
Copy-Item .\config\messages.example.json .\config\messages.local.json
```

编辑 `config\messages.local.json`：

```json
{
  "doneTitle": "Codex turn complete",
  "doneMessage": "Codex has finished the current turn.",
  "approvalTitle": "Codex approval needed",
  "approvalMessage": "Codex is waiting for permission approval."
}
```

这些文案可以换成中文，也可以换成你自己的固定提醒内容。

## 安装

建议先关闭 Codex。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

安装完成后重新打开 Codex。任务完成提醒来自 Codex 的 `notify` 配置，已经运行中的 Codex 进程可能不会立刻读取新配置。

安装脚本会做这些事情：

- 把 `codex-bark-watch.exe` 复制到 `%USERPROFILE%\.codex\hooks`
- 把你的 Bark 配置复制到 `%USERPROFILE%\.codex\hooks`
- 生成任务完成提醒配置和权限审核 watcher 配置
- 只按字节替换 `%USERPROFILE%\.codex\config.toml` 里的顶层 `notify = [...]` 这一行
- 修改 `config.toml` 前自动创建带时间戳的备份
- 给权限审核 watcher 添加 Windows 开机隐藏自启快捷方式
- 生成 watchdog 脚本，watcher 退出后会自动拉起
- 立刻启动 watchdog 和权限审核 watcher

如果原来没有顶层 `notify` 配置，安装脚本会把新的顶层 `notify` 插入到第一个 TOML 表之前。如果原来已经有顶层 `notify` 配置，安装脚本会保存原始命令，并在 Bark 发送后继续调用它。

## 编码安全

安装脚本不会把 `config.toml` 当普通文本整体重写。它会读取原始字节，只替换 ASCII 的顶层 `notify = [...]` 那一行。

这样可以尽量避免破坏中文路径、中文项目名、中文配置内容。

如果 `config.toml` 已经带 UTF-8 BOM，安装脚本会拒绝修改。建议先备份并处理 BOM，或者恢复一份干净的配置文件。

## 测试权限审核提醒

安装并重新打开 Codex 后，让 Codex 执行一个需要权限审核的操作。Codex 把这次审核请求写入 session JSONL 后，watcher 会发送一次 Bark。

watcher 第一次发现已有 session 文件时，会从文件末尾开始监听，所以不会把历史审核请求重新推送一遍。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall-windows.ps1
```

然后恢复最新的 `config.toml` 备份：

```powershell
Copy-Item "$env:USERPROFILE\.codex\config.toml.backup-codex-bark-watch-YYYYMMDDHHMMSS" "$env:USERPROFILE\.codex\config.toml" -Force
```

恢复后重新打开 Codex。

## 日志

安装后的日志目录：

```text
%USERPROFILE%\.codex\hooks\logs
```

常用日志文件：

- `notify.log`
- `approval-watcher.log`
- `approval-watcher-state.json`

## 注意事项

- Bark 的频率限制取决于你的服务商或账号套餐。
- 权限审核 watcher 通过 Windows Startup 文件夹里的隐藏快捷方式开机自启。
- watchdog 会守护 watcher，进程退出后会自动重新拉起。
- 不要把真实 Bark token、`*.local.json`、日志文件、生成的 exe 提交到仓库。

如果没有收到提醒，请看 [docs/troubleshooting.md](docs/troubleshooting.md)。

更多实现细节：

- [权限审核 watcher 说明](docs/watcher.md)
- [架构说明](docs/architecture.md)
