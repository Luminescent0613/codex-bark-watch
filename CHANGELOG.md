# 更新日志

## 未发布

- 添加 Codex 任务完成后的 Bark 推送。
- 添加 Codex 权限审核请求的 session 日志监听器。
- 添加 Windows 安装脚本、卸载脚本和 Bark 测试脚本。
- 安装时采用先备份、再按字节修改 `config.toml` 的策略。
- 添加中文 README、架构说明、故障排查和贡献指南。
- 将权限审核 watcher 的开机启动改为隐藏快捷方式加 watchdog，避免 `.cmd` 黑框，并在 watcher 退出后自动重启。
