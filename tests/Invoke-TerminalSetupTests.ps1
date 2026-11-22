$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\..\scripts\Terminal-Setup.ps1"
$temp = Join-Path (Split-Path $PSScriptRoot -Parent) "test-results\terminal-setup-$([guid]::NewGuid())"
$null = New-Item -ItemType Directory -Path $temp -Force
$path = "$temp\settings.json"
if ((Get-CtrTerminalSetup -SettingsPath $path).status -ne 'missing') { throw 'Missing settings misclassified.' }
foreach ($case in @(
    @{ json = '{broken'; status = 'malformed' },
    @{ json = 'null'; status = 'malformed' },
    @{ json = '{"startupActions":"new-tab"}'; status = 'disabled' },
    @{ json = '{"firstWindowPreference":"unknown"}'; status = 'unverified' },
    @{ json = '{"firstWindowPreference":"persistedWindowLayout"}'; status = 'recognized' },
    @{ json = "{`n// comment`n`"firstWindowPreference`":`"persistedLayoutAndContent`",`n}"; status = 'recognized' }
)) {
    $case.json | Set-Content -LiteralPath $path
    $before = (Get-FileHash -LiteralPath $path).Hash
    if ((Get-CtrTerminalSetup -SettingsPath $path).status -ne $case.status) { throw "Wrong status for $($case.json)" }
    if ((Get-FileHash -LiteralPath $path).Hash -ne $before) { throw 'Diagnostic modified settings.' }
}
Write-Output 'Read-only Terminal diagnostics: missing, malformed, disabled, unknown, legacy, and JSON-with-comments settings passed.'
