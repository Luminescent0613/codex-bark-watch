# 架构说明

## 任务完成提醒

Codex Desktop 支持在 `%USERPROFILE%\.codex\config.toml` 中配置：

```toml
notify = [...]
```

安装脚本会包装这条通知命令：

```text
Codex notify
  -> codex-bark-watch.exe
  -> Bark
  -> 原来的 notify 命令
```

原始 notify 命令和参数会保存到：

```text
%USERPROFILE%\.codex\hooks\codex-bark-watch.notify.json
```

这样做的目的，是在增加 Bark 提醒的同时，尽量保留 Codex 原本的通知行为。

## 权限审核提醒

Codex Desktop 会把会话事件写入 session JSONL 文件。需要用户授权的 shell 命令通常会记录为函数调用，并在参数里包含：

```json
{
  "sandbox_permissions": "require_escalated"
}
```

watcher 会轮询最近的 session JSONL 文件，发现这类调用后发送 Bark。

为了避免重复提醒，watcher 会按 call id 去重。没有 call id 时，会用时间戳和命令内容生成一个兜底 key。

## 状态文件

权限审核 watcher 会记录每个 session 文件的读取偏移量，以及已经推送过的 call id：

```text
%USERPROFILE%\.codex\hooks\logs\approval-watcher-state.json
```

第一次发现已有 session 文件时，watcher 会从文件末尾开始监听，避免把历史事件全部重新推送。

## Watchdog 和开机自启

安装脚本会创建：

```text
%USERPROFILE%\.codex\hooks\codex-bark-watch-watchdog.ps1
```

并在 Windows Startup 文件夹里创建隐藏快捷方式：

```text
codex-bark-watch-approval.lnk
```

开机登录后，快捷方式会隐藏启动 watchdog。watchdog 负责启动权限审核 watcher，并在 watcher 退出后自动重新拉起。

早期 `.cmd` 启动方式容易出现开机黑框。新版安装脚本如果发现旧 `.cmd`，会先备份再改名禁用。

## 配置文件修改策略

安装脚本不会整体重写 `config.toml`。它会：

- 读取原始字节
- 查找顶层 `notify = [...]` 所在行
- 创建备份
- 只替换这一行；如果没有该行，则把新的顶层 `notify` 插入到第一个 TOML 表之前

这是为了尽量保护中文路径、中文项目名和已有配置内容。
