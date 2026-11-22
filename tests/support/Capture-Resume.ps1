$ErrorActionPreference = 'Stop'
$args | ConvertTo-Json -AsArray | Set-Content -LiteralPath $env:CTR_CAPTURE_ARGUMENTS
$path = Join-Path $env:CTR_STATE_HOME "sessions\$($env:WT_SESSION).json"
$record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$record.owner = (& $env:CTR_CAPTURE_CORE shell-owner "$PID" | ConvertFrom-Json)
$record.state = 'armed'
$record.generation = 'confirmed-test-resume'
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path
