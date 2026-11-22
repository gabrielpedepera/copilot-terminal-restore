param(
    [Parameter(Mandatory)][string]$Plugin,
    [Parameter(Mandatory)][string]$SessionId,
    [switch]$Resume,
    [string]$Wrapper,
    [switch]$NoPrompt
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Initialize-ProbeConsole.ps1"
if ($env:CTR_PROBE_NATIVE) {
    $env:CTR_SHELL_OWNER = (& $env:CTR_PROBE_NATIVE shell-owner "$PID" | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Native shell registration failed.' }
}
$arguments = @('--plugin-dir', $Plugin, '--disable-builtin-mcps', '--no-auto-update')
if (-not $NoPrompt) {
    $arguments += @('--interactive', 'Reply exactly CTR_PROBE_OK. Do not use any tools.')
}
if ($env:CTR_PROBE_RESTORE -eq '1') {
    $decision = & $env:CTR_PROBE_NATIVE init | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0 -or $decision.action -ne 'restore') { throw 'Automatic restoration did not obtain a claim.' }
    if ($decision.sessionId -ne $SessionId) { throw 'Automatic restoration selected the wrong conversation.' }
    Set-Location -LiteralPath $decision.cwd
    $arguments += @('--resume', $decision.sessionId)
}
elseif ($Resume) { $arguments += @('--resume', $SessionId) }
else { $arguments += @('--session-id', $SessionId) }
$executable = if ($Wrapper) { $Wrapper }
elseif ($env:COPILOT_CLI_PATH) { $env:COPILOT_CLI_PATH }
else { (Get-Command copilot).Source }
$start = [System.Diagnostics.ProcessStartInfo]::new($executable)
$start.UseShellExecute = $false
if ($Wrapper) { $start.ArgumentList.Add('copilot') }
foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
$child = [System.Diagnostics.Process]::Start($start)
if ($env:CTR_PROBE_RESTORE -eq '1') {
    & $env:CTR_PROBE_NATIVE launched $decision.generation "$($child.Id)"
    if ($LASTEXITCODE -ne 0) { throw 'Resume launcher registration failed.' }
}
$child.WaitForExit()
if ($env:CTR_PROBE_NATIVE) {
    & $env:CTR_PROBE_NATIVE prompt
    if ($LASTEXITCODE -ne 0) { throw 'Native prompt notification failed.' }
}
@{ event = 'shell-return'; terminalSessionId = $env:WT_SESSION; exitCode = $child.ExitCode } |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $env:CTR_PROBE_LOG 'shell-return.json')
