param(
    [Parameter(Mandatory)][string]$ModulePath,
    [string]$GuardProfile
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path $root "test-results\theme-import-$([guid]::NewGuid())"
$cache = Join-Path $temp 'powershell\Community\Terminal-Icons'
$null = New-Item -ItemType Directory -Path $cache -Force
$guardScript = $null
if ($GuardProfile) {
    $profileText = [IO.File]::ReadAllText($GuardProfile)
    $match = [regex]::Match($profileText,
        '(?ms)^# BEGIN Terminal-Icons synchronized import\r?\n.*?^# END Terminal-Icons synchronized import')
    if (-not $match.Success) { throw 'Synchronized import block not found in the profile.' }
    $guardScript = Join-Path $temp 'guard.ps1'
    $match.Value.Replace('Import-Module -Name Terminal-Icons', 'Import-Module -Name $ModulePath') |
        Set-Content -LiteralPath $guardScript
}
$source = @'
param($ModulePath, $CacheRoot, $OutputPath, $GuardScript)
$env:APPDATA = $CacheRoot
$Error.Clear()
if ($GuardScript) {
    . $GuardScript
} else {
    Import-Module $ModulePath
}
@($Error | ForEach-Object {
    @{ message = $_.Exception.Message; stack = $_.ScriptStackTrace }
}) | ConvertTo-Json -Depth 4 -AsArray | Set-Content -LiteralPath $OutputPath
'@
$driver = Join-Path $temp 'import.ps1'
$source | Set-Content -LiteralPath $driver
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$processes = @()
foreach ($i in 1..8) {
    $start = [Diagnostics.ProcessStartInfo]::new($pwsh)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($arg in @('-NoLogo', '-NoProfile', '-File', $driver, $ModulePath, $temp, "$temp\result-$i.json")) {
        $start.ArgumentList.Add($arg)
    }
    if ($guardScript) { $start.ArgumentList.Add($guardScript) }
    $child = [Diagnostics.Process]::Start($start)
    $processes += @{
        Child = $child
        Output = $child.StandardOutput.ReadToEndAsync()
        Error = $child.StandardError.ReadToEndAsync()
    }
}
foreach ($entry in $processes) {
    try {
        if (-not $entry.Child.WaitForExit(60000)) {
            Stop-Process -Id $entry.Child.Id -Force
            throw 'Isolated theme import timed out.'
        }
        if ($entry.Child.ExitCode -ne 0) { throw $entry.Error.GetAwaiter().GetResult() }
    }
    finally { $entry.Child.Dispose() }
}
$errorsFound = @(Get-ChildItem -LiteralPath $temp -Filter 'result-*.json' | ForEach-Object {
    Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json
})
[pscustomobject]@{
    isolatedCache = $temp
    guarded = [bool]$GuardProfile
    imports = $processes.Count
    errors = $errorsFound
} | ConvertTo-Json -Depth 5
if ($GuardProfile -and $errorsFound.Count) { throw 'Concurrent guarded theme imports reported errors.' }
