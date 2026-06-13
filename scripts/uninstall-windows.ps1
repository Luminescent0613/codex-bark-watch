Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$hooksDir = Join-Path $env:USERPROFILE ".codex\hooks"
$exePath = Join-Path $hooksDir "codex-bark-watch.exe"
$watchdogScript = Join-Path $hooksDir "codex-bark-watch-watchdog.ps1"
$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$startupShortcut = Join-Path $startupDir "codex-bark-watch-approval.lnk"
$legacyStartupScript = Join-Path $startupDir "codex-bark-watch-approval.cmd"

Get-Process -Name "codex-bark-watch" -ErrorAction SilentlyContinue |
    Where-Object {
        try { $_.Path -eq $exePath } catch { $false }
    } |
    Stop-Process -Force

Get-CimInstance Win32_Process -Filter "name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*codex-bark-watch-watchdog.ps1*" } |
    ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

if (Test-Path $startupShortcut) {
    Remove-Item -LiteralPath $startupShortcut -Force
}
if (Test-Path $legacyStartupScript) {
    Remove-Item -LiteralPath $legacyStartupScript -Force
}
if (Test-Path $watchdogScript) {
    Remove-Item -LiteralPath $watchdogScript -Force
}

Write-Output "Stopped watcher and removed startup shortcut/watchdog."
Write-Output "To restore Codex notify, copy the latest $env:USERPROFILE\.codex\config.toml.backup-codex-bark-watch-* over $env:USERPROFILE\.codex\config.toml."
