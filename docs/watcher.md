# 权限审核 watcher

`watcher` 是本项目里负责“Codex 等待权限审核时提醒用户”的后台组件。

Codex 的任务完成提醒可以通过 `notify` 配置触发，但权限审核场景不一定有稳定的通知 hook。为了让用户不必一直盯着电脑，本项目选择监听 Codex 本地 session JSONL 日志。

## 它解决什么问题

当 Codex 需要执行需要用户确认的操作时，例如带有 `sandbox_permissions=require_escalated` 的命令，Codex 会先等待用户在界面里审核。

如果用户正在做别的事情，就可能错过这个审核弹窗，导致任务停在那里。`watcher` 的作用就是发现这类等待审核的事件，并立刻通过 Bark 推送到手机或手表。

## 工作流程

```text
Codex session JSONL
  -> watcher 读取新增事件
  -> 发现 sandbox_permissions=require_escalated
  -> 根据 call_id 去重
  -> 发送 Bark
  -> 手机收到通知
  -> 系统通知同步到手表
```

## 识别规则

watcher 会轮询最近的 Codex session JSONL 文件，读取新增的 JSONL 行。

当它发现 `response_item` 里包含函数调用，并且调用参数中出现：

```json
{
  "sandbox_permissions": "require_escalated"
}
```

就认为 Codex 正在等待用户审核权限，然后发送一次 Bark 通知。

## 去重机制

为了避免同一个审核请求反复推送，watcher 会记录已经提醒过的 `call_id`。

如果某条记录没有 `call_id`，watcher 会使用时间戳和命令内容生成一个兜底 key。

状态文件保存在：

```text
%USERPROFILE%\.codex\hooks\logs\approval-watcher-state.json
```

## 为什么不会补发历史提醒

watcher 第一次发现已有 session 文件时，会从文件末尾开始监听。

这样做是为了避免安装后把历史权限审核请求全部重新推送一遍。安装完成后，需要触发一次新的权限审核，才能验证 watcher 是否正常工作。

## 如何保持后台运行

安装脚本会生成两个东西：

- `watcher`：真正负责监听 session JSONL 并发送 Bark。
- `watchdog`：负责守护 watcher，如果 watcher 退出，就重新拉起。

同时，安装脚本会在 Windows Startup 文件夹里创建一个隐藏的 `.lnk` 快捷方式。用户登录 Windows 后，这个快捷方式会隐藏启动 watchdog。

因此正常情况下，用户不需要每次打开终端，也不会看到开机黑色命令行窗口。

## 日志

常用日志文件：

```text
%USERPROFILE%\.codex\hooks\logs\approval-watcher.log
%USERPROFILE%\.codex\hooks\logs\approval-watchdog.log
%USERPROFILE%\.codex\hooks\logs\approval-watcher-state.json
```

如果权限审核提醒收不到，优先检查 watcher 是否在运行：

```powershell
Get-Process -Name codex-bark-watch -ErrorAction SilentlyContinue
```

再检查日志：

```powershell
Get-Content "$env:USERPROFILE\.codex\hooks\logs\approval-watcher.log" -Tail 50
Get-Content "$env:USERPROFILE\.codex\hooks\logs\approval-watchdog.log" -Tail 50
```

## 限制

- watcher 依赖 Codex 本地 session JSONL 的结构。如果 Codex 未来修改日志格式，本项目可能需要适配。
- watcher 只会推送启动之后发现的新审核请求，不会补发历史请求。
- 手表能否收到通知取决于手机系统、Bark App 通知权限，以及手表通知同步设置。
