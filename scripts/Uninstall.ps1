[CmdletBinding()]
param([string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CopilotTerminalRestore\app'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $InstallRoot 'installation.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Output 'No installation manifest found; nothing removed.'
    return
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (Test-Path -LiteralPath $manifest.hookPath) {
    $current = [IO.File]::ReadAllText($manifest.hookPath).Trim()
    if ($current -ne $manifest.installedHook.Trim()) {
        throw 'Hook was edited after installation; refusing to remove it.'
    }
}
if (Test-Path -LiteralPath $manifest.profilePath) {
    $content = [IO.File]::ReadAllText($manifest.profilePath)
    $pattern = '(?ms)^# BEGIN copilot-terminal-restore\r?\n.*?^# END copilot-terminal-restore(?:\r?\n)?'
    $stripped = [regex]::Replace($content, $pattern, '')
    $backup = $manifest.profileBackup
    $original = if ($backup -and (Test-Path -LiteralPath $backup)) { [IO.File]::ReadAllText($backup) } else { $null }
    # Restore or delete the whole profile only when nothing but the owned block was added.
    if ($manifest.profileCreated -and $stripped.Trim().Length -eq 0) {
        Remove-Item -LiteralPath $manifest.profilePath
    }
    elseif ($null -ne $original -and ($stripped -ceq $original -or $stripped -ceq "$original`r`n")) {
        Copy-Item -LiteralPath $backup -Destination $manifest.profilePath -Force
    }
    elseif ($stripped -cne $content) {
        [IO.File]::WriteAllText($manifest.profilePath, $stripped, [Text.UTF8Encoding]::new($false))
    }
}
if (Test-Path -LiteralPath $manifest.hookPath) { Remove-Item -LiteralPath $manifest.hookPath }
Remove-Item -LiteralPath $manifestPath
Write-Output 'Profile block and owned hooks removed. Binary, backups, and recovery records retained.'
