param([int]$Samples = 10)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$native = Join-Path $root 'target\release\copilot-terminal-restore.exe'
$pwsh = (Get-Command pwsh).Source
$script = Join-Path $PSScriptRoot 'support\Get-ProbeOwner.ps1'
$results = foreach ($engine in @('Rust', 'PowerShell')) {
    $measurements = @(for ($i = 0; $i -lt $Samples + 1; $i++) {
        $time = Measure-Command {
            if ($engine -eq 'Rust') { & $native shell-owner "$PID" | Out-Null }
            else { & $pwsh -NoLogo -NoProfile -File $script -OwnerPid $PID | Out-Null }
            if ($LASTEXITCODE -ne 0) { throw "$engine probe failed." }
        }
        if ($i -gt 0) { $time.TotalMilliseconds }
    }) | Sort-Object
    [pscustomobject]@{
        engine = $engine; samples = $Samples
        medianMs = [math]::Round($measurements[[int][math]::Floor($Samples / 2)], 2)
        p95Ms = [math]::Round($measurements[[math]::Min($Samples - 1, [int][math]::Ceiling($Samples * 0.95) - 1)], 2)
    }
}
$results | ConvertTo-Json
