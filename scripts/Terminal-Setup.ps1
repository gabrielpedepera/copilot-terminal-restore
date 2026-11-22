function Get-CtrTerminalSetup {
    [CmdletBinding()]
    param([string]$SettingsPath)
    Set-StrictMode -Version Latest
    if (-not $SettingsPath) {
        $paths = @(
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json",
            "$env:LOCALAPPDATA\Packages\Microsoft.WindowsTerminalPreview_8wekyb3d8bbwe\LocalState\settings.json",
            "$env:LOCALAPPDATA\Microsoft\Windows Terminal\settings.json"
        )
        $found = @($paths | Where-Object { Test-Path -LiteralPath $_ })
        if ($found.Count -gt 1) {
            return [pscustomobject]@{ status = 'ambiguous'; path = $null; mode = $null; detail = 'Specify -SettingsPath; multiple Terminal settings files exist.' }
        }
        $SettingsPath = $found | Select-Object -First 1
    }
    if (-not $SettingsPath -or -not (Test-Path -LiteralPath $SettingsPath)) {
        return [pscustomobject]@{ status = 'missing'; path = $SettingsPath; mode = $null; detail = 'No Terminal settings file found.' }
    }
    try { $settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json -ErrorAction Stop }
    catch {
        return [pscustomobject]@{ status = 'malformed'; path = $SettingsPath; mode = $null; detail = 'Settings could not be parsed; inspect the file in Terminal.' }
    }
    if ($null -eq $settings -or $settings -isnot [pscustomobject]) {
        return [pscustomobject]@{ status = 'malformed'; path = $SettingsPath; mode = $null; detail = 'Settings must be a JSON object.' }
    }
    $property = $settings.PSObject.Properties['firstWindowPreference']
    $mode = if ($property) { $property.Value } else { $null }
    $status = if ($mode -in @('persistedLayoutAndContent', 'persistedWindowLayout')) { 'recognized' }
        elseif (-not $mode -or $mode -eq 'defaultProfile') { 'disabled' }
        else { 'unverified' }
    [pscustomobject]@{
        status = $status; path = $SettingsPath; mode = $mode
        detail = 'Recognition does not prove runtime/version compatibility. Validate whole-window restoration.'
    }
}
