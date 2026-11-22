param(
    [ValidateSet('Exit', 'Close', 'Resume', 'Wrapper')][string]$Scenario = 'Exit',
    # Launcher executable for the Wrapper scenario; it receives 'copilot' as its first argument.
    [string]$Wrapper,
    [string]$SessionId = [guid]::NewGuid().ToString(),
    [ValidateSet('PowerShell', 'Rust')][string]$Engine = 'PowerShell',
    [string]$RestoreFrom,
    [switch]$NoPrompt,
    [int]$TimeoutSeconds = 45
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$result = Join-Path $root "test-results\$Scenario-$([guid]::NewGuid())"
$plugin = Join-Path $result 'plugin'
$null = New-Item -ItemType Directory -Path "$plugin\hooks" -Force
$oldLog = $env:CTR_PROBE_LOG
$oldTerminal = $env:WT_SESSION
$oldNative = $env:CTR_PROBE_NATIVE
$oldState = $env:CTR_STATE_HOME
$oldOwner = $env:CTR_SHELL_OWNER
$oldRestore = $env:CTR_PROBE_RESTORE
$env:CTR_PROBE_LOG = $result
$env:WT_SESSION = [guid]::NewGuid().ToString()
$env:CTR_STATE_HOME = Join-Path $result 'state'
if ($RestoreFrom) {
    if ($Engine -ne 'Rust') { throw 'Automatic restoration probe requires the Rust engine.' }
    $prior = Get-ChildItem -LiteralPath (Join-Path $RestoreFrom 'state\sessions') -Filter '*.json'
    if (@($prior).Count -ne 1) { throw 'RestoreFrom must contain exactly one native terminal record.' }
    $previous = Get-Content -LiteralPath $prior.FullName -Raw | ConvertFrom-Json
    $env:WT_SESSION = $previous.terminalId
    $SessionId = $previous.sessionId
    $env:CTR_STATE_HOME = Join-Path $RestoreFrom 'state'
    $env:CTR_PROBE_RESTORE = '1'
}
else { $env:CTR_PROBE_RESTORE = $null }
if ($Engine -eq 'Rust') {
    $env:CTR_PROBE_NATIVE = Join-Path $root 'target\release\copilot-terminal-restore.exe'
}
else { $env:CTR_PROBE_NATIVE = $null }
$pwsh = (Get-Command pwsh).Source
$hook = Join-Path $PSScriptRoot 'support\Record-Probe.ps1'
@{ name = 'ctr-lifecycle-probe'; version = '0.1.0'; hooks = 'hooks/hooks.json' } |
    ConvertTo-Json | Set-Content -LiteralPath "$plugin\plugin.json"
$hooks = @{}
foreach ($event in @('sessionStart', 'sessionEnd')) {
    $entry = @{
        type = 'command'; exec = $pwsh
        args = @('-NoLogo', '-NoProfile', '-File', $hook, '-Event', $event)
        timeoutSec = 10
    }
    if ($Engine -eq 'Rust') {
        $entry.exec = $env:CTR_PROBE_NATIVE
        $entry.args = @('hook', $(if ($event -eq 'sessionStart') { 'start' } else { 'end' }))
    }
    $hooks[$event] = @($entry)
}
@{ version = 1; hooks = $hooks } | ConvertTo-Json -Depth 7 |
    Set-Content -LiteralPath "$plugin\hooks\hooks.json"
if (-not ('CopilotTerminalRestore.Tests.PseudoTerminal' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'support\PseudoTerminal.cs')
}
$driver = Join-Path $PSScriptRoot 'support\Invoke-ProbeShell.ps1'
$command = "`"$pwsh`" -NoLogo -NoProfile -File `"$driver`" -Plugin `"$plugin`" -SessionId $SessionId"
if ($Scenario -eq 'Resume') { $command += ' -Resume' }
if ($Scenario -eq 'Wrapper') {
    if (-not $Wrapper) { throw 'The Wrapper scenario requires -Wrapper.' }
    $command += " -Wrapper `"$((Get-Command $Wrapper -CommandType Application).Source)`""
}
if ($NoPrompt) { $command += ' -NoPrompt' }
$terminal = $null
try {
    $terminal = [CopilotTerminalRestore.Tests.PseudoTerminal]::new($command, $root)
    $deadline = [datetime]::UtcNow.AddSeconds($TimeoutSeconds)
    $trustSent = $false
    while ([datetime]::UtcNow -lt $deadline) {
        $nativeRecord = Join-Path $env:CTR_STATE_HOME "sessions\$($env:WT_SESSION).json"
        $nativeStarted = $false
        if ($Engine -eq 'Rust' -and (Test-Path -LiteralPath $nativeRecord)) {
            $saved = Get-Content -LiteralPath $nativeRecord -Raw | ConvertFrom-Json
            $nativeStarted = ($saved.state -eq 'armed' -and
                (-not $RestoreFrom -or $saved.generation -ne $previous.generation)) -or
                ($NoPrompt -and $saved.state -eq 'awaitingHook')
        }
        if ((Get-ChildItem -LiteralPath $result -Filter 'sessionStart-*.json') -or $nativeStarted) { break }
        if ($terminal.HasExited) { throw 'Probe exited before the start hook.' }
        if (-not $trustSent -and $terminal.Output -match 'trust this folder|trust this directory') {
            $terminal.Send("`r")
            $trustSent = $true
        }
        Start-Sleep -Milliseconds 250
    }
    if (-not (Get-ChildItem -LiteralPath $result -Filter 'sessionStart-*.json') -and
        -not $nativeStarted) {
        throw 'No sessionStart hook within the bounded probe timeout.'
    }
    if ($NoPrompt) {
        $deadline = [datetime]::UtcNow.AddSeconds(40)
        while ($terminal.Output -notmatch 'Manual Approval' -and [datetime]::UtcNow -lt $deadline) {
            if ($terminal.HasExited) { throw 'Idle resume exited before the interactive composer appeared.' }
            Start-Sleep -Milliseconds 250
        }
        if ($terminal.Output -notmatch 'Manual Approval') { throw 'Idle resume did not reach the interactive composer.' }
    }
    if ($Scenario -eq 'Close') { $terminal.CloseConsole() }
    else {
        Start-Sleep -Seconds 8
        $terminal.Send([string][char]3)
        Start-Sleep -Seconds 1
        $terminal.Send([string][char]21)
        $terminal.Send("/exit`r")
    }
    $deadline = [datetime]::UtcNow.AddSeconds(15)
    while (-not $terminal.HasExited -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 200
    }
    $records = @(Get-ChildItem -LiteralPath $result -Filter '*.json' |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
    [pscustomobject]@{
        scenario = $Scenario; requestedSessionId = $SessionId; resultDirectory = $result
        exited = $terminal.HasExited
        events = @($records | Select-Object event, sessionId, source, reason, terminalSessionId, hookDepth)
        nativeRecord = $(if (Test-Path -LiteralPath $nativeRecord) { Get-Content -LiteralPath $nativeRecord -Raw | ConvertFrom-Json })
    } | ConvertTo-Json -Depth 5
}
finally {
    if ($terminal) {
        $terminal.Output | Set-Content -LiteralPath (Join-Path $result 'terminal-output.txt')
        $terminal.CloseConsole()
        if (-not $terminal.HasExited) { Stop-Process -Id $terminal.ProcessId -Force -ErrorAction Stop }
        $terminal.Dispose()
    }
    $env:CTR_PROBE_LOG = $oldLog
    $env:WT_SESSION = $oldTerminal
    $env:CTR_PROBE_NATIVE = $oldNative
    $env:CTR_STATE_HOME = $oldState
    $env:CTR_SHELL_OWNER = $oldOwner
    $env:CTR_PROBE_RESTORE = $oldRestore
    Write-Output "Probe output: $result"
}
