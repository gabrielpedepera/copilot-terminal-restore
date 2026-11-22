[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CopilotTerminalRestore\app'),
    [string]$SettingsPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$core = Join-Path $InstallRoot 'copilot-terminal-restore.exe'
if (-not (Test-Path -LiteralPath $core)) { throw "Helper is not installed at $core" }
& $core doctor
if ($LASTEXITCODE -ne 0) { throw 'Environment diagnostic failed.' }
Write-Output "PowerShell: $($PSVersionTable.PSVersion)"
Write-Output "Terminal output redirected: $([Console]::IsOutputRedirected)"
. "$PSScriptRoot\Terminal-Setup.ps1"
Get-CtrTerminalSetup -SettingsPath $SettingsPath | ConvertTo-Json
Write-Output 'Directory reporting: manually verify by changing directory, closing the whole window, and reopening. WT_SESSION alone does not prove cwd reporting.'
