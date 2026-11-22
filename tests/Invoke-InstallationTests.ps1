$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path $root "test-results\install-$([guid]::NewGuid())"
$app = Join-Path $temp 'app'
$homePath = Join-Path $temp 'copilot'
$profilePath = Join-Path $temp 'profile.ps1'
$state = Join-Path $temp 'state'
$null = New-Item -ItemType Directory -Path "$homePath\hooks" -Force
$unrelatedHook = '{"version":1,"hooks":{}}'
$unrelatedHook | Set-Content -LiteralPath "$homePath\hooks\existing.json"
$baseline = "# Existing profile`r`nfunction prompt { 'unchanged> ' }`r`n"
[IO.File]::WriteAllText($profilePath, $baseline)
foreach ($i in 1..2) {
    & "$root\scripts\Install.ps1" -InstallRoot $app -CopilotHome $homePath -ProfilePath $profilePath `
        -StateHome $state -Executable (Get-Command pwsh).Source
}
$profileText = [IO.File]::ReadAllText($profilePath)
if ([regex]::Matches($profileText, '# BEGIN copilot-terminal-restore').Count -ne 1) {
    throw 'Repeated installation duplicated the profile block.'
}
if (-not $profileText.StartsWith($baseline)) { throw 'Existing profile content changed.' }
$hook = Get-Content -LiteralPath "$homePath\hooks\copilot-terminal-restore.json" -Raw | ConvertFrom-Json
if ($hook.hooks.sessionStart[0].exec -ne "$app\copilot-terminal-restore.exe") {
    throw 'Hook does not point to the installed executable.'
}
$manifestBefore = Get-Content -LiteralPath "$app\installation.json" -Raw | ConvertFrom-Json
$recordPath = "$state\sessions\11111111-1111-1111-1111-111111111111.json"
$null = New-Item -ItemType Directory -Path (Split-Path $recordPath) -Force
'{"synthetic":"preserve state"}' | Set-Content -LiteralPath $recordPath
$recordHash = (Get-FileHash -LiteralPath $recordPath).Hash
$configText = [IO.File]::ReadAllText("$state\config.json")
'{"executable":"copilot","args":["--prompt=unexpected"]}' | Set-Content -LiteralPath "$state\config.json"
'# Simulated previously installed adapter' | Set-Content -LiteralPath "$app\shell\CopilotTerminalRestore.psm1"
$upgradePaths = @("$app\copilot-terminal-restore.exe", "$app\shell\CopilotTerminalRestore.psm1",
    "$app\installation.json", $profilePath, "$homePath\hooks\copilot-terminal-restore.json", "$state\config.json")
$upgradeHashes = @{}
foreach ($path in $upgradePaths) { $upgradeHashes[$path] = (Get-FileHash -LiteralPath $path).Hash }
$expectedFailure = $false
try {
    & "$root\scripts\Install.ps1" -InstallRoot $app -CopilotHome $homePath -ProfilePath $profilePath `
        -StateHome $state -Executable (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
}
catch { $expectedFailure = $true }
if (-not $expectedFailure) { throw 'Upgrade accepted an invalid existing config.' }
foreach ($path in $upgradePaths) {
    if ((Get-FileHash -LiteralPath $path).Hash -ne $upgradeHashes[$path]) { throw "Failed upgrade changed $path" }
}
[IO.File]::WriteAllText("$state\config.json", $configText)
& "$root\scripts\Install.ps1" -InstallRoot $app -CopilotHome $homePath -ProfilePath $profilePath `
    -StateHome $state -Executable (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$manifestAfter = Get-Content -LiteralPath "$app\installation.json" -Raw | ConvertFrom-Json
if ($manifestBefore.profileBackup -ne $manifestAfter.profileBackup -or
    (Get-FileHash -LiteralPath $recordPath).Hash -ne $recordHash -or
    [IO.File]::ReadAllText("$state\config.json") -ne $configText) { throw 'Upgrade lost backup, state, or config.' }
& "$root\scripts\Uninstall.ps1" -InstallRoot $app
& "$root\scripts\Uninstall.ps1" -InstallRoot $app
if (Test-Path -LiteralPath "$homePath\hooks\copilot-terminal-restore.json") { throw 'Owned hook was not removed.' }
if ((Get-Content -LiteralPath "$homePath\hooks\existing.json" -Raw).Trim() -ne $unrelatedHook) {
    throw 'Unrelated hook changed.'
}
if ([IO.File]::ReadAllText($profilePath).Contains('# BEGIN copilot-terminal-restore')) {
    throw 'Owned profile block was not removed.'
}
if (-not [IO.File]::ReadAllText($profilePath).StartsWith($baseline)) { throw 'Uninstall changed existing profile.' }
if ([IO.File]::ReadAllText($profilePath) -ne $baseline) { throw 'Original profile was not restored exactly.' }

$rollbackState = Join-Path $temp 'invalid-state'
$null = New-Item -ItemType Directory -Path $rollbackState
'{"executable":"copilot","args":["--prompt=unexpected"]}' |
    Set-Content -LiteralPath "$rollbackState\config.json"
$expectedFailure = $false
try {
    & "$root\scripts\Install.ps1" -InstallRoot "$temp\rollback-app" -CopilotHome $homePath `
        -ProfilePath $profilePath -StateHome $rollbackState -Executable (Get-Command pwsh).Source
}
catch { $expectedFailure = $true }
if (-not $expectedFailure) { throw 'Invalid launcher configuration was accepted.' }
if ((Test-Path -LiteralPath "$homePath\hooks\copilot-terminal-restore.json") -or
    [IO.File]::ReadAllText($profilePath) -ne $baseline) {
    throw 'Failed installation did not roll back its profile/hook changes.'
}
if (Test-Path -LiteralPath "$temp\rollback-app\copilot-terminal-restore.exe") {
    throw 'Failed first installation retained application files.'
}
& "$root\scripts\Install.ps1" -InstallRoot $app -CopilotHome $homePath -ProfilePath $profilePath `
    -StateHome $state -Executable (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$edit = "# Unrelated post-install profile edit`r`n"
[IO.File]::AppendAllText($profilePath, $edit)
& "$root\scripts\Uninstall.ps1" -InstallRoot $app
if (-not [IO.File]::ReadAllText($profilePath).Contains($edit)) { throw 'Uninstall removed a later profile edit.' }

$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
function Invoke-TestInstall([string]$Target, [string]$AppRoot = $app, [string]$StateRoot = $state, [switch]$Reporting) {
    $extra = @{}
    if ($Reporting) { $extra.EnableDirectoryReporting = $true }
    & "$root\scripts\Install.ps1" -InstallRoot $AppRoot -CopilotHome $homePath -ProfilePath $Target `
        -StateHome $StateRoot -Executable $pwsh @extra | Out-Null
}
# Reinstall between a user edit and uninstall must not restore a stale backup or delete the profile.
$createdProfile = Join-Path $temp 'created-profile.ps1'
foreach ($target in @($profilePath, $createdProfile)) {
    Invoke-TestInstall $target
    $later = "# Edit made between install and upgrade`r`n"
    [IO.File]::AppendAllText($target, $later)
    Invoke-TestInstall $target
    $upgraded = [IO.File]::ReadAllText($target)
    if ($upgraded.IndexOf('# BEGIN copilot-terminal-restore') -gt $upgraded.IndexOf($later)) {
        throw 'Reinstall moved the profile block below later user content.'
    }
    & "$root\scripts\Uninstall.ps1" -InstallRoot $app | Out-Null
    if (-not (Test-Path -LiteralPath $target) -or -not [IO.File]::ReadAllText($target).Contains($later) -or
        [IO.File]::ReadAllText($target).Contains('# BEGIN copilot-terminal-restore')) {
        throw "Reinstall followed by uninstall lost later edits in $target."
    }
}
Remove-Item -LiteralPath $createdProfile
Invoke-TestInstall $createdProfile
& "$root\scripts\Uninstall.ps1" -InstallRoot $app | Out-Null
if (Test-Path -LiteralPath $createdProfile) { throw 'Uninstall left an otherwise empty installer-created profile.' }
Invoke-TestInstall $profilePath
Remove-Item -LiteralPath (Get-Content -LiteralPath "$app\installation.json" -Raw | ConvertFrom-Json).profileBackup
& "$root\scripts\Uninstall.ps1" -InstallRoot $app | Out-Null
if ([IO.File]::ReadAllText($profilePath).Contains('# BEGIN copilot-terminal-restore')) {
    throw 'Uninstall without a backup did not strip the owned block.'
}
Write-Output 'Reinstall/uninstall preserves later edits, block position, created profiles, and missing-backup removal.'

# Typographic quotes close PowerShell single-quoted strings, so generated paths must be escaped.
$quotedApp = Join-Path $temp "O$([char]0x2019)Brien's app"
$quotedState = Join-Path $temp "state $([char]0x2018)q$([char]0x201B)"
$quotedProfile = Join-Path $temp 'quoted-profile.ps1'
Invoke-TestInstall $quotedProfile -AppRoot $quotedApp -StateRoot $quotedState -Reporting
Invoke-TestInstall $quotedProfile -AppRoot $quotedApp -StateRoot $quotedState
$block = [IO.File]::ReadAllText($quotedProfile)
if ($block -notmatch '(?ms)Enable-CtrDirectoryReporting\r?\n\s*Enable-CtrRestore') {
    throw 'Directory reporting option was not written before Enable-CtrRestore or not kept on reinstall.'
}
$env:CTR_TEST_PROFILE = $quotedProfile
try {
    $loaded = & $pwsh -NoLogo -NoProfile -Command '$env:WT_SESSION = $null; . $env:CTR_TEST_PROFILE; $env:CTR_STATE_HOME; [bool](Get-Command Enable-CtrDirectoryReporting)' 2>&1
}
finally { Remove-Item Env:\CTR_TEST_PROFILE }
if ($LASTEXITCODE -ne 0 -or $loaded[0] -ne $quotedState -or $loaded[1] -ne 'True') {
    throw "Generated profile block with quoted paths did not load correctly: $loaded"
}
# A synced profile on a machine without the installation must load without errors.
Rename-Item -LiteralPath "$quotedApp\shell" -NewName 'shell-missing'
$env:CTR_TEST_PROFILE = $quotedProfile
try {
    $missing = & $pwsh -NoLogo -NoProfile -Command '$ErrorActionPreference = ''Stop''; . $env:CTR_TEST_PROFILE; [bool](Get-Command Enable-CtrRestore -ErrorAction SilentlyContinue)' 2>&1
}
finally {
    Remove-Item Env:\CTR_TEST_PROFILE
    Rename-Item -LiteralPath "$quotedApp\shell-missing" -NewName 'shell'
}
if ($LASTEXITCODE -ne 0 -or "$missing" -ne 'False') {
    throw "Profile block failed when the installation is absent: $missing"
}
& "$root\scripts\Uninstall.ps1" -InstallRoot $quotedApp | Out-Null
Write-Output 'Quoted install paths and the persisted directory-reporting option load correctly.'

$files = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
    Where-Object FullName -NotMatch '\\(target|test-results|dist)\\')
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw "$($file.FullName): $($parseErrors -join '; ')" }
}
Write-Output "Installation round-trip, idempotency, unrelated settings, and $($files.Count) PowerShell parse checks passed."
