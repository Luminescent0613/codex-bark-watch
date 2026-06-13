param(
    [string]$ConfigPath = "$PSScriptRoot\..\config\bark.local.json"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Test-Path $ConfigPath)) {
    throw "Bark config not found: $ConfigPath. Copy config\bark.example.json to config\bark.local.json first."
}

$bytes = [System.IO.File]::ReadAllBytes($ConfigPath)
$offset = 0
if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    $offset = 3
}
$text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $offset, $bytes.Length - $offset)
$cfg = $text | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace([string]$cfg.baseUrl) -or [string]::IsNullOrWhiteSpace([string]$cfg.token) -or [string]$cfg.token -eq "replace-with-your-token") {
    throw "Please set baseUrl and token in $ConfigPath first."
}

$payload = [ordered]@{
    token = [string]$cfg.token
    title = "Codex Bark Watch test"
    msg = "If this appears on your phone/watch, Bark is ready."
    url = if ($null -ne $cfg.url) { [string]$cfg.url } else { "" }
    issecure = if ($null -ne $cfg.issecure) { [int]$cfg.issecure } else { 0 }
    sender = if ($null -ne $cfg.sender) { [string]$cfg.sender } else { "Codex Bark Watch" }
}

Invoke-RestMethod -Uri ([string]$cfg.baseUrl) -Method POST -ContentType "application/json" -Body ($payload | ConvertTo-Json -Depth 5)
