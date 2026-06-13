# 贡献指南

欢迎一起改进 Codex Bark Watch。

提交前请注意：

- 不要提交个人 Bark token。
- 不要提交 `*.local.json`、安装后的配置、日志文件或生成的 exe。
- Windows 安装逻辑必须坚持“先备份，再修改”。
- 不要把 `%USERPROFILE%\.codex\config.toml` 当普通文本整体重写。
- 修改 `config.toml` 时，应尽量保留原始字节，只处理必要的 `notify` 行。
- 默认提醒文案应保持中性，并允许用户自行配置。

提交 PR 前建议运行：

```powershell
gofmt -w .\cmd\codex-bark-watch\main.go .\cmd\codex-bark-watch\main_test.go
go test .\cmd\codex-bark-watch
go build -o dist\codex-bark-watch.exe .\cmd\codex-bark-watch
```

如果改动了安装脚本，请额外检查：

- 是否会创建 `config.toml` 备份
- 是否能处理中文路径
- 是否避免重复包装 `notify`
- 是否避免开机黑框，并能在 watcher 退出后自动拉起
- 是否不会把真实用户目录、token 或日志内容写入仓库
