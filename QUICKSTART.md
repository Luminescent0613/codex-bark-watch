# 快速开始：无需 Go 环境

这个发布包已经包含编译好的 `codex-bark-watch.exe`，普通用户不需要安装 Go。

## 你需要准备

- Windows
- Codex Desktop
- Bark 或 Bark 兼容推送服务
- 手机上的 Bark App 或兼容 App
- 如果要推送到手表，需要在手机系统和手表 App 里允许 Bark 通知同步

## 第一步：配置 Bark

复制配置文件：

```powershell
Copy-Item .\config\bark.example.json .\config\bark.local.json
```

编辑：

```powershell
notepad .\config\bark.local.json
```

把里面的 `baseUrl` 和 `token` 改成你自己的 Bark 配置。

## 第二步：测试 Bark

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-bark.ps1
```

手机能收到测试通知后，再继续安装。

## 第三步：安装

建议先关闭 Codex Desktop。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-windows.ps1
```

安装脚本会自动完成：

- 复制 `codex-bark-watch.exe` 到 `%USERPROFILE%\.codex\hooks`
- 备份 `%USERPROFILE%\.codex\config.toml`
- 写入 Codex 任务完成提醒 hook
- 安装权限审核 watcher
- 安装 watchdog
- 创建 Windows 开机隐藏自启
- 立刻启动 watcher/watchdog

安装完成后，重新打开 Codex Desktop。

## 是否需要每次运行

不需要。

`install-windows.ps1` 正常只需要运行一次。安装后：

- 任务完成提醒会通过 Codex 的 `notify` 配置长期生效。
- 权限审核提醒会通过 Windows 开机启动项自动恢复。
- watchdog 会在 watcher 退出后自动重新拉起。

只有更换 Bark token、升级版本、卸载重装，或者 Codex 配置被重置时，才需要重新安装。

## 卸载

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\uninstall-windows.ps1
```

如果要恢复 Codex 原来的 `notify` 配置，请把最新的备份复制回：

```text
%USERPROFILE%\.codex\config.toml
```

备份文件名类似：

```text
config.toml.backup-codex-bark-watch-20260613123000
```

## 收不到通知

请看：

```text
docs\troubleshooting.md
```
