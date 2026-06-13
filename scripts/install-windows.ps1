param(
    [string]$BarkConfigPath = "$PSScriptRoot\..\config\bark.local.json",
    [string]$MessagesConfigPath = "$PSScriptRoot\..\config\messages.local.json",
    [switch]$SkipNotifyPatch,
    [switch]$SkipStartup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$codexHome = Join-Path $env:USERPROFILE ".codex"
$hooksDir = Join-Path $codexHome "hooks"
$logsDir = Join-Path $hooksDir "logs"
$configToml = Join-Path $codexHome "config.toml"
$exeSource = Join-Path $repoRoot "dist\codex-bark-watch.exe"
$exeTarget = Join-Path $hooksDir "codex-bark-watch.exe"
$installedBarkConfig = Join-Path $hooksDir "codex-bark-watch.bark.json"
$notifyConfig = Join-Path $hooksDir "codex-bark-watch.notify.json"
$approvalConfig = Join-Path $hooksDir "codex-bark-watch.approval.json"
$watchdogScript = Join-Path $hooksDir "codex-bark-watch-watchdog.ps1"
$startupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
$startupShortcut = Join-Path $startupDir "codex-bark-watch-approval.lnk"
$legacyStartupScript = Join-Path $startupDir "codex-bark-watch-approval.cmd"

function Get-AsciiBytes { param([string]$Text) [System.Text.Encoding]::ASCII.GetBytes($Text) }
function Get-Utf8NoBomBytes { param([string]$Text) (New-Object System.Text.UTF8Encoding($false)).GetBytes($Text) }
function Get-Utf8NoBomText {
    param([byte[]]$Bytes, [int]$Index, [int]$Count)
    (New-Object System.Text.UTF8Encoding($false, $true)).GetString($Bytes, $Index, $Count)
}

function Test-StartsWithAt {
    param([byte[]]$Bytes, [int]$Offset, [byte[]]$Needle)
    if ($Offset + $Needle.Length -gt $Bytes.Length) { return $false }
    for ($i = 0; $i -lt $Needle.Length; $i++) {
        if ($Bytes[$Offset + $i] -ne $Needle[$i]) { return $false }
    }
    return $true
}

function Find-NotifyLine {
    param([byte[]]$Bytes)
    $needle = Get-AsciiBytes "notify"
    $matches = @()
    $lineStart = 0
    for ($i = 0; $i -le $Bytes.Length; $i++) {
        if ($i -eq $Bytes.Length -or $Bytes[$i] -eq 10) {
            $lineEnd = $i
            if ($lineEnd -gt $lineStart -and $Bytes[$lineEnd - 1] -eq 13) { $lineEnd-- }
            $cursor = $lineStart
            while ($cursor -lt $lineEnd -and ($Bytes[$cursor] -eq 32 -or $Bytes[$cursor] -eq 9)) { $cursor++ }
            if ($cursor -lt $lineEnd -and $Bytes[$cursor] -eq 91) {
                break
            }
            if (Test-StartsWithAt -Bytes $Bytes -Offset $cursor -Needle $needle) {
                $after = $cursor + $needle.Length
                while ($after -lt $lineEnd -and ($Bytes[$after] -eq 32 -or $Bytes[$after] -eq 9)) { $after++ }
                if ($after -lt $lineEnd -and $Bytes[$after] -eq 61) {
                    $matches += [pscustomobject]@{
                        Start = $lineStart
                        End = $lineEnd
                        Text = Get-Utf8NoBomText -Bytes $Bytes -Index $lineStart -Count ($lineEnd - $lineStart)
                    }
                }
            }
            $lineStart = $i + 1
        }
    }
    if ($matches.Count -gt 1) { throw "Expected at most one notify line, found $($matches.Count)." }
    if ($matches.Count -eq 0) { return $null }
    $matches[0]
}

function Find-FirstTableLineStart {
    param([byte[]]$Bytes)
    $lineStart = 0
    for ($i = 0; $i -le $Bytes.Length; $i++) {
        if ($i -eq $Bytes.Length -or $Bytes[$i] -eq 10) {
            $lineEnd = $i
            if ($lineEnd -gt $lineStart -and $Bytes[$lineEnd - 1] -eq 13) { $lineEnd-- }
            $cursor = $lineStart
            while ($cursor -lt $lineEnd -and ($Bytes[$cursor] -eq 32 -or $Bytes[$cursor] -eq 9)) { $cursor++ }
            if ($cursor -lt $lineEnd -and $Bytes[$cursor] -eq 91) {
                return $lineStart
            }
            $lineStart = $i + 1
        }
    }
    return $Bytes.Length
}

function ConvertFrom-TomlBasicString {
    param([string]$Value)
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $Value.Length; $i++) {
        $ch = $Value[$i]
        if ($ch -ne '\') {
            [void]$sb.Append($ch)
            continue
        }
        $i++
        if ($i -ge $Value.Length) {
            [void]$sb.Append('\')
            break
        }
        $next = $Value[$i]
        switch ($next) {
            'b' { [void]$sb.Append([char]8) }
            't' { [void]$sb.Append("`t") }
            'n' { [void]$sb.Append("`n") }
            'f' { [void]$sb.Append([char]12) }
            'r' { [void]$sb.Append("`r") }
            '"' { [void]$sb.Append('"') }
            '\' { [void]$sb.Append('\') }
            default { [void]$sb.Append($next) }
        }
    }
    $sb.ToString()
}

function ConvertTo-TomlBasicString {
    param([string]$Value)
    '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function Write-JsonNoBom {
    param([string]$Path, [object]$Data)
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    $json = $Data | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllBytes($Path, $utf8NoBom.GetBytes($json + "`n"))
}

function Read-Utf8JsonFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        $offset = 3
    }
    $text = (New-Object System.Text.UTF8Encoding($false, $true)).GetString($bytes, $offset, $bytes.Length - $offset)
    $text | ConvertFrom-Json
}

function Write-WatchdogScript {
    param([string]$Path)
    $lines = @(
        '$ErrorActionPreference = "Continue"',
        '$exe = Join-Path $env:USERPROFILE ".codex\hooks\codex-bark-watch.exe"',
        '$config = Join-Path $env:USERPROFILE ".codex\hooks\codex-bark-watch.approval.json"',
        '$log = Join-Path $env:USERPROFILE ".codex\hooks\logs\approval-watchdog.log"',
        '$createdNew = $false',
        '$mutex = New-Object System.Threading.Mutex($true, "Local\CodexBarkWatchApprovalWatchdog", [ref]$createdNew)',
        'function Write-WatchdogLog {',
        '    param([string]$Message)',
        '    $dir = Split-Path -Parent $log',
        '    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }',
        '    Add-Content -LiteralPath $log -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -Encoding UTF8',
        '}',
        'if (-not $createdNew) { Write-WatchdogLog "watchdog already running"; return }',
        'function Get-ExistingWatcher {',
        '    Get-Process -Name "codex-bark-watch" -ErrorAction SilentlyContinue |',
        '        Where-Object {',
        '            try { $_.Path -eq $exe } catch { $false }',
        '        } |',
        '        Sort-Object StartTime |',
        '        Select-Object -First 1',
        '}',
        'Write-WatchdogLog "watchdog started"',
        'while ($true) {',
        '    try {',
        '        if (-not (Test-Path $exe)) { Write-WatchdogLog ("missing exe: " + $exe); Start-Sleep -Seconds 30; continue }',
        '        if (-not (Test-Path $config)) { Write-WatchdogLog ("missing config: " + $config); Start-Sleep -Seconds 30; continue }',
        '        $process = Get-ExistingWatcher',
        '        if ($null -ne $process) {',
        '            Write-WatchdogLog ("watcher already running pid=" + $process.Id)',
        '        } else {',
        '            $process = Start-Process -FilePath $exe -ArgumentList @("watch-approvals", $config) -WindowStyle Hidden -PassThru',
        '            Write-WatchdogLog ("watcher started pid=" + $process.Id)',
        '        }',
        '        Wait-Process -Id $process.Id',
        '        Write-WatchdogLog ("watcher exited pid=" + $process.Id)',
        '    } catch {',
        '        Write-WatchdogLog ("watchdog error: " + $_.Exception.Message)',
        '    }',
        '    Start-Sleep -Seconds 5',
        '}'
    )
    [System.IO.File]::WriteAllBytes($Path, (Get-Utf8NoBomBytes (($lines -join "`r`n") + "`r`n")))
}

function New-HiddenStartupShortcut {
    param([string]$ShortcutPath, [string]$ScriptPath, [string]$WorkingDirectory)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ShortcutPath) | Out-Null
    $target = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
    $args = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $ScriptPath + '"'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($ShortcutPath)
    $shortcut.TargetPath = $target
    $shortcut.Arguments = $args
    $shortcut.WorkingDirectory = $WorkingDirectory
    $shortcut.WindowStyle = 7
    $shortcut.Description = "Hidden watchdog for Codex Bark Watch approval notifications"
    $shortcut.Save()
}

if (-not (Test-Path $exeSource)) {
    throw "Executable not found: $exeSource. Run: go build -o dist\codex-bark-watch.exe .\cmd\codex-bark-watch"
}
if (-not (Test-Path $BarkConfigPath)) {
    throw "Bark config not found: $BarkConfigPath. Copy config\bark.example.json to config\bark.local.json first."
}

$messages = @{
    doneTitle = "Codex turn complete"
    doneMessage = "Codex has finished the current turn."
    approvalTitle = "Codex approval needed"
    approvalMessage = "Codex is waiting for permission approval."
}
if (Test-Path $MessagesConfigPath) {
    $loaded = Read-Utf8JsonFile -Path $MessagesConfigPath
    foreach ($property in $loaded.PSObject.Properties) {
        $messages[$property.Name] = [string]$property.Value
    }
}

New-Item -ItemType Directory -Force -Path $hooksDir | Out-Null
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null
Copy-Item -LiteralPath $exeSource -Destination $exeTarget -Force
Copy-Item -LiteralPath $BarkConfigPath -Destination $installedBarkConfig -Force

if (-not $SkipNotifyPatch) {
    if (-not (Test-Path $configToml)) { throw "Codex config not found: $configToml" }
    $bytes = [System.IO.File]::ReadAllBytes($configToml)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw "Refusing to patch config.toml because it already has a UTF-8 BOM."
    }
    $notifyLine = Find-NotifyLine -Bytes $bytes
    $originalCommand = ""
    $originalArgs = @()
    if ($null -ne $notifyLine) {
        if ($notifyLine.Text -like "*codex-bark-watch*") { throw "notify already appears to use codex-bark-watch." }
        $quoted = [regex]::Matches($notifyLine.Text, '"((?:\\.|[^"])*)"')
        if ($quoted.Count -lt 1) { throw "Could not parse original notify line: $($notifyLine.Text)" }
        $originalCommand = ConvertFrom-TomlBasicString $quoted[0].Groups[1].Value
        for ($i = 1; $i -lt $quoted.Count; $i++) { $originalArgs += ConvertFrom-TomlBasicString $quoted[$i].Groups[1].Value }
    }

    Write-JsonNoBom -Path $notifyConfig -Data ([ordered]@{
        barkConfigPath = $installedBarkConfig
        title = $messages.doneTitle
        message = $messages.doneMessage
        originalCommand = $originalCommand
        originalArgs = $originalArgs
        logPath = (Join-Path $logsDir "notify.log")
    })

    $backup = Join-Path $codexHome ("config.toml.backup-codex-bark-watch-" + (Get-Date -Format "yyyyMMddHHmmss"))
    Copy-Item -LiteralPath $configToml -Destination $backup -Force
    $cmdArg = '"%USERPROFILE%\.codex\hooks\codex-bark-watch.exe" "%USERPROFILE%\.codex\hooks\codex-bark-watch.notify.json"'
    $newNotifyLine = 'notify = [ ' + (ConvertTo-TomlBasicString "cmd.exe") + ', ' + (ConvertTo-TomlBasicString "/d") + ', ' + (ConvertTo-TomlBasicString "/s") + ', ' + (ConvertTo-TomlBasicString "/c") + ', ' + (ConvertTo-TomlBasicString $cmdArg) + ' ]'
    if ($null -eq $notifyLine) {
        $insertAt = Find-FirstTableLineStart -Bytes $bytes
        if ($insertAt -lt $bytes.Length) {
            $insert = Get-Utf8NoBomBytes ($newNotifyLine + "`r`n")
            $newBytes = New-Object byte[] ($bytes.Length + $insert.Length)
            [System.Array]::Copy($bytes, 0, $newBytes, 0, $insertAt)
            [System.Array]::Copy($insert, 0, $newBytes, $insertAt, $insert.Length)
            [System.Array]::Copy($bytes, $insertAt, $newBytes, $insertAt + $insert.Length, $bytes.Length - $insertAt)
        } else {
            $appendText = $newNotifyLine + "`r`n"
            if ($bytes.Length -gt 0 -and $bytes[$bytes.Length - 1] -ne 10) {
                $appendText = "`r`n" + $appendText
            }
            $append = Get-Utf8NoBomBytes $appendText
            $newBytes = New-Object byte[] ($bytes.Length + $append.Length)
            [System.Array]::Copy($bytes, 0, $newBytes, 0, $bytes.Length)
            [System.Array]::Copy($append, 0, $newBytes, $bytes.Length, $append.Length)
        }
    } else {
        $replacement = Get-Utf8NoBomBytes $newNotifyLine
        $newBytes = New-Object byte[] ($notifyLine.Start + $replacement.Length + ($bytes.Length - $notifyLine.End))
        [System.Array]::Copy($bytes, 0, $newBytes, 0, $notifyLine.Start)
        [System.Array]::Copy($replacement, 0, $newBytes, $notifyLine.Start, $replacement.Length)
        [System.Array]::Copy($bytes, $notifyLine.End, $newBytes, $notifyLine.Start + $replacement.Length, $bytes.Length - $notifyLine.End)
    }
    [System.IO.File]::WriteAllBytes($configToml, $newBytes)
}

Write-JsonNoBom -Path $approvalConfig -Data ([ordered]@{
    barkConfigPath = $installedBarkConfig
    sessionsRoot = (Join-Path $codexHome "sessions")
    statePath = (Join-Path $logsDir "approval-watcher-state.json")
    logPath = (Join-Path $logsDir "approval-watcher.log")
    pollIntervalMs = 1500
    approvalTitle = $messages.approvalTitle
    approvalMessage = $messages.approvalMessage
})

if (-not $SkipStartup) {
    $timestamp = Get-Date -Format "yyyyMMddHHmmss"
    if (Test-Path $watchdogScript) {
        Copy-Item -LiteralPath $watchdogScript -Destination ($watchdogScript + ".backup-$timestamp") -Force
    }
    if (Test-Path $startupShortcut) {
        Copy-Item -LiteralPath $startupShortcut -Destination ($startupShortcut + ".backup-$timestamp") -Force
    }
    if (Test-Path $legacyStartupScript) {
        Copy-Item -LiteralPath $legacyStartupScript -Destination ($legacyStartupScript + ".backup-$timestamp") -Force
        Move-Item -LiteralPath $legacyStartupScript -Destination ($legacyStartupScript + ".disabled-$timestamp") -Force
    }

    Write-WatchdogScript -Path $watchdogScript
    New-HiddenStartupShortcut -ShortcutPath $startupShortcut -ScriptPath $watchdogScript -WorkingDirectory $hooksDir
    Start-Process -FilePath (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe") -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $watchdogScript) -WindowStyle Hidden
}

[ordered]@{
    executable = $exeTarget
    notifyConfig = $notifyConfig
    approvalConfig = $approvalConfig
    watchdogScript = if ($SkipStartup) { $null } else { $watchdogScript }
    startupShortcut = if ($SkipStartup) { $null } else { $startupShortcut }
} | ConvertTo-Json -Depth 5
