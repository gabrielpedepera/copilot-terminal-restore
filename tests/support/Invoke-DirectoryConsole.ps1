param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Initialize-ProbeConsole.ps1"
$start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
$start.UseShellExecute = $false
foreach ($arg in @('-NoLogo', '-NoProfile', '-File', "$PSScriptRoot\Exercise-DirectoryReporting.ps1", '-Root', $Root)) {
    $start.ArgumentList.Add($arg)
}
$child = [Diagnostics.Process]::Start($start)
try { $child.WaitForExit(); exit $child.ExitCode }
finally { $child.Dispose() }
