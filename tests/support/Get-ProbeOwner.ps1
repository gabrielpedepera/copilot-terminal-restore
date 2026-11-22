param([Parameter(Mandatory)][int]$OwnerPid)
$ErrorActionPreference = 'Stop'
$process = [Diagnostics.Process]::GetProcessById($OwnerPid)
@{ pid = $OwnerPid; created = $process.StartTime.ToUniversalTime().ToFileTimeUtc() } |
    ConvertTo-Json -Compress
