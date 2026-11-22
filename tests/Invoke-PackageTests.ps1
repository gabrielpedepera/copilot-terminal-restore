param([Parameter(Mandatory)][string]$Archive)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path $root "test-results\package space-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temp -Force
$hash = (Get-FileHash -LiteralPath $Archive -Algorithm SHA256).Hash.ToLowerInvariant()
$expected = (Get-Content -LiteralPath "$Archive.sha256" -Raw).Split(' ')[0].Trim()
if ($hash -ne $expected) { throw 'ZIP checksum mismatch.' }
Expand-Archive -LiteralPath $Archive -DestinationPath "$temp\extracted"
$package = Get-ChildItem -LiteralPath "$temp\extracted" -Directory | Select-Object -First 1
$manifest = Get-Content -LiteralPath "$($package.FullName)\package-manifest.json" -Raw | ConvertFrom-Json
$actualFiles = @(Get-ChildItem -LiteralPath $package.FullName -Recurse -File)
if ($actualFiles.Count -ne @($manifest.files).Count + 1) { throw 'Package inventory contains unexpected or missing files.' }
$required = @('copilot-terminal-restore.exe', 'Install.ps1', 'Uninstall.ps1', 'Test-Environment.ps1',
    'Terminal-Setup.ps1', 'shell\CopilotTerminalRestore.psd1', 'shell\CopilotTerminalRestore.psm1',
    'README.md', 'docs\AGENT-INSTALL.md', 'LICENSE', 'THIRD-PARTY-NOTICES.txt', 'CHANGELOG.md', 'ACCEPTANCE.md', 'CONTRIBUTING.md', 'STATE.md')
if (@(Compare-Object -ReferenceObject $required -DifferenceObject @($manifest.files.file)).Count) {
    throw 'Package does not match the public release contract.'
}
foreach ($entry in $manifest.files) {
    if ((Get-FileHash -LiteralPath (Join-Path $package.FullName $entry.file)).Hash.ToLowerInvariant() -ne $entry.sha256) {
        throw "Package file checksum mismatch: $($entry.file)"
    }
    $binaryVersion = & "$($package.FullName)\copilot-terminal-restore.exe" --version
    if ($LASTEXITCODE -or $binaryVersion -ne "copilot-terminal-restore $($manifest.version)" -or
        $manifest.target -ne 'x86_64-pc-windows-msvc') { throw 'Packaged binary/target/version mismatch.' }
}
if (Test-Path -LiteralPath "$($package.FullName)\target") { throw 'Package unexpectedly depends on source build layout.' }
$app = "$temp\installed app"
$profilePath = "$temp\profile.ps1"
$state = "$temp\state"
$homePath = "$temp\home"
$baseline = "# Isolated original profile`r`n"
[IO.File]::WriteAllText($profilePath, $baseline)
foreach ($i in 1..2) {
    & "$($package.FullName)\Install.ps1" -InstallRoot $app -StateHome $state -CopilotHome $homePath `
        -ProfilePath $profilePath -Executable (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
}
if ([IO.File]::ReadAllText($profilePath) -notlike "$baseline*") { throw 'Packaged install lost original profile.' }
$oldState = $env:CTR_STATE_HOME
try {
    $env:CTR_STATE_HOME = $state
    $null = & "$($package.FullName)\Test-Environment.ps1" -InstallRoot $app
}
finally { $env:CTR_STATE_HOME = $oldState }
& "$($package.FullName)\Uninstall.ps1" -InstallRoot $app
if ([IO.File]::ReadAllText($profilePath) -ne $baseline) { throw 'Packaged uninstall failed exact profile restoration.' }
if (Test-Path -LiteralPath "$homePath\hooks\copilot-terminal-restore.json") { throw 'Packaged hook was not removed.' }
Write-Output 'Public ZIP checksum, file inventory, extracted install/reinstall/diagnostics/uninstall passed without source layout or user authentication.'
