param([Parameter(Mandatory)][string]$Event)
$ErrorActionPreference = 'Stop'
$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
$ancestors = @()
$next = $PID
for ($i = 0; $i -lt 8 -and $next; $i++) {
    $owner = Get-CimInstance Win32_Process -Filter "ProcessId=$next"
    if (-not $owner) { break }
    $ancestors += @{
        pid = $owner.ProcessId
        parent = $owner.ParentProcessId
        name = $owner.Name
        created = $owner.CreationDate.ToUniversalTime().ToString('o')
        noninteractive = [bool]($owner.CommandLine -match '(?:^|\s)(?:-p|--prompt)(?:\s|=|$)')
    }
    $next = $owner.ParentProcessId
}
$record = @{
    event = $Event
    sessionId = $(if ($payload.sessionId) { $payload.sessionId } else { $payload.session_id })
    source = $payload.source
    reason = $payload.reason
    cwd = $payload.cwd
    terminalSessionId = $env:WT_SESSION
    hookDepth = $env:COPILOT_HOOK_DEPTH
    ancestors = $ancestors
}
$name = '{0}-{1}.json' -f $Event, [guid]::NewGuid()
$record | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $env:CTR_PROBE_LOG $name)
