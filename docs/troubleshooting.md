# 故障排查

## Bark 测试收不到

先运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-bark.ps1
```

如果测试失败，先检查 `config\bark.local.json`。常见原因包括：

- `baseUrl` 不正确
- `token` 不正确
- 网络无法访问 Bark 服务
- Bark 服务商或账号触发频率限制

## 任务完成提醒收不到

安装后请重新打开 Codex。Codex 会从 `%USERPROFILE%\.codex\config.toml` 读取 `notify`，已经运行中的 Codex 进程可能还保留旧配置。

检查日志：

```powershell
Get-Content "$env:USERPROFILE\.codex\hooks\logs\notify.log" -Tail 50
```

检查 `config.toml` 中是否存在 `notify`：

```powershell
Select-String -Path "$env:USERPROFILE\.codex\config.toml" -Pattern "notify"
```

## 权限审核提醒收不到

先确认 watcher 是否正在运行：

```powershell
Get-Process -Name codex-bark-watch -ErrorAction SilentlyContinue
```

再检查 watcher 日志：

```powershell
Get-Content "$env:USERPROFILE\.codex\hooks\logs\approval-watcher.log" -Tail 50
```

watcher 第一次看到已有 session 文件时，会从文件末尾开始监听，不会推送旧的审核请求。请在 watcher 启动后触发一次新的权限审核。

## 重启电脑后权限审核提醒不工作

检查 Startup 文件夹里是否有隐藏自启快捷方式：

```powershell
Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup" |
  Where-Object { $_.Name -match "codex|bark|approval|watch" }
```

如果没有，可以重新运行安装脚本。

新版安装脚本使用 `.lnk` 快捷方式隐藏启动 watchdog。旧版本如果留下了 `.cmd`，可能会在开机时出现黑框；重新运行新版安装脚本会备份并禁用旧 `.cmd`。

检查 watchdog 日志：

```powershell
Get-Content "$env:USERPROFILE\.codex\hooks\logs\approval-watchdog.log" -Tail 50
```

## 恢复之前的 Codex 配置

安装脚本在修改 `config.toml` 之前会创建备份：

```powershell
Get-ChildItem "$env:USERPROFILE\.codex\config.toml.backup-codex-bark-watch-*"
```

恢复最新备份：

```powershell
Copy-Item "$env:USERPROFILE\.codex\config.toml.backup-codex-bark-watch-YYYYMMDDHHMMSS" "$env:USERPROFILE\.codex\config.toml" -Force
```

恢复后重新打开 Codex。

## 重复安装

如果 `notify` 已经指向 `codex-bark-watch`，安装脚本会停止，避免把自己重复包装。

需要重装时，建议先运行卸载脚本，必要时恢复备份，再重新安装。

## 编码和中文路径

安装脚本不会整体重写 TOML 文件，只会围绕顶层 `notify` 行做字节级修改。因此文件中的 UTF-8 中文路径、中文项目名和中文配置内容会保留。

如果 `config.toml` 已经带 UTF-8 BOM，安装脚本会拒绝修改。请先备份文件，再手动处理 BOM，或者恢复一份干净备份。
