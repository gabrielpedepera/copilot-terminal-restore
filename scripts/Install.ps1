[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CopilotTerminalRestore\app'),
    [string]$CopilotHome = $(if ($env:COPILOT_HOME) { $env:COPILOT_HOME } else { Join-Path $env:USERPROFILE '.copilot' }),
    [string]$ProfilePath = $PROFILE.CurrentUserCurrentHost,
    [string]$StateHome = (Join-Path $env:LOCALAPPDATA 'CopilotTerminalRestore'),
    [string]$Executable = 'copilot',
    [string[]]$LauncherArguments = @(),
    [switch]$EnableDirectoryReporting
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne 'X64' -or
    [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture -ne 'X64' -or
    $PSVersionTable.PSVersion -lt [version]'7.4') {
    throw 'Requires Windows x64 and PowerShell 7.4 or newer.'
}
$project = if (Test-Path -LiteralPath "$PSScriptRoot\copilot-terminal-restore.exe") {
    $PSScriptRoot
} else { Split-Path $PSScriptRoot -Parent }
$binary = Join-Path $project 'copilot-terminal-restore.exe'
if (-not (Test-Path -LiteralPath $binary)) {
    $binary = Join-Path $project 'target\release\copilot-terminal-restore.exe'
}
foreach ($file in @($binary, "$project\shell\CopilotTerminalRestore.psd1", "$project\shell\CopilotTerminalRestore.psm1",
    "$PSScriptRoot\Test-Environment.ps1", "$PSScriptRoot\Terminal-Setup.ps1")) {
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw "Incomplete package/build: missing $file" }
}
$fullPaths = @($InstallRoot, $CopilotHome, $ProfilePath, $StateHome)
foreach ($path in $fullPaths) {
    if (-not [IO.Path]::IsPathFullyQualified($path)) { throw "Installation paths must be absolute: $path" }
}
$null = Get-Command -Name $Executable -CommandType Application -ErrorAction Stop
$hookPath = Join-Path $CopilotHome 'hooks\copilot-terminal-restore.json'
$manifestPath = Join-Path $InstallRoot 'installation.json'
$previous = if (Test-Path -LiteralPath $manifestPath) {
    Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
} else { $null }
$marker = '# BEGIN copilot-terminal-restore'
if ((Test-Path -LiteralPath $hookPath) -and -not (Test-Path -LiteralPath $manifestPath)) {
    throw "Refusing to overwrite an existing hook not owned by this installation: $hookPath"
}
if ((Test-Path -LiteralPath $hookPath) -and (Test-Path -LiteralPath $manifestPath)) {
    if ([IO.File]::ReadAllText($hookPath).Trim() -ne $previous.installedHook.Trim()) {
        throw 'Hook was edited after installation; refusing to overwrite it.'
    }
}
if ($previous -and ($previous.profilePath -ne $ProfilePath -or $previous.hookPath -ne $hookPath)) {
    throw 'Uninstall the previous integration before changing its profile or Copilot home.'
}
$originalProfileExists = Test-Path -LiteralPath $ProfilePath
$content = if ($originalProfileExists) { [IO.File]::ReadAllText($ProfilePath) } else { '' }
$pattern = '(?ms)^# BEGIN copilot-terminal-restore\r?\n.*?^# END copilot-terminal-restore(?:\r?\n)?'
if ($content.Contains($marker) -and -not [regex]::IsMatch($content, $pattern)) {
    throw 'Existing helper profile block is incomplete; repair it before installing.'
}
foreach ($dir in @($InstallRoot, "$InstallRoot\shell", (Split-Path $hookPath), (Split-Path $ProfilePath), $StateHome)) {
    $null = New-Item -ItemType Directory -Path $dir -Force
}
$stamp = [guid]::NewGuid().ToString()
$profileBackup = "$ProfilePath.ctr-$stamp.bak"
if ($previous) { $profileBackup = $previous.profileBackup }
elseif ($originalProfileExists) { Copy-Item -LiteralPath $ProfilePath -Destination $profileBackup }
$core = Join-Path $InstallRoot 'copilot-terminal-restore.exe'
$hooks = @{}
foreach ($pair in @(@('sessionStart', 'start'), @('sessionEnd', 'end'))) {
    $hooks[$pair[0]] = @(@{
        type = 'command'; exec = $core; args = @('hook', $pair[1]); timeoutSec = 5
    })
}
$hookDocument = @{ version = 1; hooks = $hooks } | ConvertTo-Json -Depth 6
$configPath = Join-Path $StateHome 'config.json'
$directoryReporting = if ($PSBoundParameters.ContainsKey('EnableDirectoryReporting')) {
    [bool]$EnableDirectoryReporting
} elseif ($previous -and $previous.PSObject.Properties['directoryReporting']) {
    [bool]$previous.directoryReporting
} else { $false }
$escape = { param($text) [Management.Automation.Language.CodeGeneration]::EscapeSingleQuotedStringContent($text) }
$module = & $escape (Join-Path $InstallRoot 'shell\CopilotTerminalRestore.psd1')
$state = & $escape $StateHome
$reportingLine = if ($directoryReporting) { "    Enable-CtrDirectoryReporting`r`n" } else { '' }
# Synced profiles (for example OneDrive) can reach machines without this installation; skip quietly there.
$block = "$marker`r`nif (Test-Path -LiteralPath '$module') {`r`n" +
    "    `$env:CTR_STATE_HOME = '$state'`r`n    Import-Module '$module'`r`n" +
    "${reportingLine}    Enable-CtrRestore`r`n}`r`n# END copilot-terminal-restore`r`n"
# Reinstalling keeps the block where the user's profile already has it.
$existing = [regex]::Match($content, $pattern)
if ($existing.Success) {
    $newProfile = [regex]::Replace($content, $pattern, '').Insert($existing.Index, $block)
} else {
    $separator = if ($content.Length -and -not $content.EndsWith("`n")) { "`r`n" } else { '' }
    $newProfile = $content + $separator + $block
}
$snapshots = @{}
foreach ($path in @($hookPath, $configPath, $ProfilePath, $manifestPath, $core,
    "$InstallRoot\shell\CopilotTerminalRestore.psd1", "$InstallRoot\shell\CopilotTerminalRestore.psm1",
    "$InstallRoot\Terminal-Setup.ps1")) {
    $snapshots[$path] = $null
    if (Test-Path -LiteralPath $path) { $snapshots[$path] = [IO.File]::ReadAllBytes($path) }
}
try {
    Copy-Item -LiteralPath $binary -Destination $core -Force
    Copy-Item -LiteralPath "$project\shell\CopilotTerminalRestore.psd1" -Destination "$InstallRoot\shell" -Force
    Copy-Item -LiteralPath "$project\shell\CopilotTerminalRestore.psm1" -Destination "$InstallRoot\shell" -Force
    Copy-Item -LiteralPath "$PSScriptRoot\Terminal-Setup.ps1" -Destination $InstallRoot -Force
    if (-not (Test-Path -LiteralPath $configPath)) {
        @{ executable = $Executable; args = $LauncherArguments } | ConvertTo-Json |
            Set-Content -LiteralPath $configPath
    }
    else { Write-Output "Existing launcher configuration retained: $configPath" }
    $oldState = $env:CTR_STATE_HOME
    try {
        $env:CTR_STATE_HOME = $StateHome
        $null = & $core doctor
        if ($LASTEXITCODE -ne 0) { throw 'Launcher configuration validation failed.' }
    }
    finally { $env:CTR_STATE_HOME = $oldState }
    $hookDocument | Set-Content -LiteralPath $hookPath
    [IO.File]::WriteAllText($ProfilePath, $newProfile, [Text.UTF8Encoding]::new($false))
    @{
        version = 1; profilePath = $ProfilePath; hookPath = $hookPath; stateHome = $StateHome
        profileBackup = $(if ($previous -or $originalProfileExists) { $profileBackup } else { $null })
        profileCreated = $(if ($previous) { $previous.profileCreated } else { -not $originalProfileExists })
        directoryReporting = $directoryReporting
        installedHook = $hookDocument
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath
}
catch {
    $failure = $_
    foreach ($path in $snapshots.Keys) {
        try {
            if ($null -ne $snapshots[$path]) { [IO.File]::WriteAllBytes($path, $snapshots[$path]) }
            elseif (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path }
        }
        catch { Write-Warning "Installation rollback failed for ${path}: $($_.Exception.Message)" }
    }
    throw $failure
}
Write-Output "Installed. Load in a fresh Windows Terminal tab. Profile: $ProfilePath"
. "$PSScriptRoot\Terminal-Setup.ps1"
$terminalSetup = Get-CtrTerminalSetup
if ($terminalSetup.status -ne 'recognized') {
    Write-Warning "Terminal restore setup is $($terminalSetup.status). Settings > Startup > When Terminal starts > Open windows from a previous session."
}
if (-not $directoryReporting) {
    Write-Output 'Verify directory reporting too: rerun with -EnableDirectoryReporting for a plain PowerShell prompt, or set pwd=osc99 in your existing Oh My Posh configuration. See README.'
}
