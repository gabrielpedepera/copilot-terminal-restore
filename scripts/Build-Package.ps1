[CmdletBinding()]
param([string]$OutputDirectory = (Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$cargo = (Get-Command cargo -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$metadataText = & $cargo metadata --manifest-path "$root\Cargo.toml" --locked --format-version 1 --filter-platform x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Cargo metadata failed.' }
$metadata = $metadataText | ConvertFrom-Json
$package = $metadata.packages | Where-Object name -EQ 'copilot-terminal-restore'
$version = $package.version
if ($version -notmatch '^\d+\.\d+\.\d+(?:-[a-zA-Z0-9.-]+)?$') { throw 'Invalid package version.' }
$moduleVersion = (Import-PowerShellDataFile -LiteralPath "$root\shell\CopilotTerminalRestore.psd1").ModuleVersion
if ($moduleVersion -ne $version) { throw 'Module/package version mismatch.' }
& $cargo build --manifest-path "$root\Cargo.toml" --release --locked --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw 'Release build failed.' }
$binary = Join-Path $metadata.target_directory 'x86_64-pc-windows-msvc\release\copilot-terminal-restore.exe'
$binaryVersion = & $binary --version
if ($LASTEXITCODE -ne 0 -or $binaryVersion -ne "copilot-terminal-restore $version") { throw 'Binary/package version mismatch.' }
$stage = Join-Path $OutputDirectory "stage-$([guid]::NewGuid())"
$name = "copilot-terminal-restore-v$version-windows-x64"
$folder = Join-Path $stage $name
try {
    $null = New-Item -ItemType Directory -Path "$folder\shell" -Force
    Copy-Item -LiteralPath $binary -Destination "$folder\copilot-terminal-restore.exe"
    foreach ($file in @('Install.ps1', 'Uninstall.ps1', 'Test-Environment.ps1', 'Terminal-Setup.ps1')) {
        Copy-Item -LiteralPath "$root\scripts\$file" -Destination $folder
    }
    foreach ($file in @('CopilotTerminalRestore.psd1', 'CopilotTerminalRestore.psm1')) {
        Copy-Item -LiteralPath "$root\shell\$file" -Destination "$folder\shell"
    }
    foreach ($file in @('README.md', 'LICENSE', 'CHANGELOG.md', 'ACCEPTANCE.md', 'CONTRIBUTING.md', 'STATE.md')) {
        Copy-Item -LiteralPath "$root\$file" -Destination $folder
    }
    $notices = [Text.StringBuilder]::new()
    $null = $notices.AppendLine('Third-party dependency notices generated from Cargo.lock and source license files.')
    $resolvedIds = @($metadata.resolve.nodes.id)
    foreach ($dependency in ($metadata.packages | Where-Object { $_.name -ne $package.name -and $_.id -in $resolvedIds } | Sort-Object name)) {
        $null = $notices.AppendLine("`n=== $($dependency.name) $($dependency.version) ($($dependency.license)) ===")
        $licenses = @(Get-ChildItem -LiteralPath (Split-Path $dependency.manifest_path) -File |
            Where-Object Name -Match '^(LICENSE|COPYING)' | Sort-Object Name)
        if (-not $licenses.Count) { throw "No license file found for $($dependency.name); review before packaging." }
        foreach ($license in $licenses) {
            $null = $notices.AppendLine("--- $($license.Name) ---")
            $null = $notices.AppendLine([IO.File]::ReadAllText($license.FullName))
        }
    }
    [IO.File]::WriteAllText("$folder\THIRD-PARTY-NOTICES.txt", $notices.ToString(), [Text.UTF8Encoding]::new($false))
    $manifest = foreach ($file in (Get-ChildItem -LiteralPath $folder -Recurse -File | Sort-Object FullName)) {
        [pscustomobject]@{
            file = $file.FullName.Substring($folder.Length + 1)
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    @{ version = $version; target = 'x86_64-pc-windows-msvc'; files = @($manifest) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$folder\package-manifest.json"
    $zip = Join-Path $OutputDirectory "$name.zip"
    Compress-Archive -LiteralPath $folder -DestinationPath $zip -Force
    $hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    "$hash  $name.zip" | Set-Content -LiteralPath "$zip.sha256" -Encoding ascii
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
[pscustomobject]@{ archive = $zip; sha256 = $hash; version = $version; target = 'windows-x64' }
