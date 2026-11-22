param([string]$Theme)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$temp = Join-Path $root "test-results\adapter-$([guid]::NewGuid())"
$resumeDirectory = "$temp\space $([char]0x00e9) directory"
$null = New-Item -ItemType Directory -Path "$temp\sessions", "$temp\home\session-state\00000000-0000-0000-0000-000000000002", $resumeDirectory
$savedEnvironment = @{}
foreach ($key in @('CTR_STATE_HOME', 'WT_SESSION', 'CTR_SHELL_OWNER', 'CTR_CAPTURE_ARGUMENTS', 'CTR_CAPTURE_CORE')) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
}
$location = Get-Location
$originalPrompt = (Get-Command prompt).ScriptBlock
$originalPath = $env:PATH
try {
    $env:CTR_STATE_HOME = $temp
    $env:WT_SESSION = '00000000-0000-0000-0000-000000000001'
    $env:CTR_CAPTURE_CORE = "$root\target\release\copilot-terminal-restore.exe"
    $env:CTR_CAPTURE_ARGUMENTS = "$temp\arguments.json"
    $env:CTR_SHELL_OWNER = (& $env:CTR_CAPTURE_CORE shell-owner "$PID" | Out-String).Trim()
    $owner = $env:CTR_SHELL_OWNER | ConvertFrom-Json
    $record = @{
        version = 1; terminalId = $env:WT_SESSION; sessionId = '00000000-0000-0000-0000-000000000002'
        cwd = $resumeDirectory; copilotHome = "$temp\home"
        owner = @{ pid = [uint32]::MaxValue - 1; created = 1 }; shell = @{ pid = [uint32]::MaxValue - 1; created = 1 }
        generation = 'initial'; state = 'armed'; attempts = 0; message = $null
    }
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$temp\sessions\$($env:WT_SESSION).json"
    @{
        executable = (Get-Command pwsh).Source
        args = @('-NoLogo', '-NoProfile', '-File', "$PSScriptRoot\support\Capture-Resume.ps1")
    } | ConvertTo-Json | Set-Content -LiteralPath "$temp\config.json"
    $module = Import-Module "$root\shell\CopilotTerminalRestore.psd1" -PassThru
    $launcherName = "ctr-launcher-$([guid]::NewGuid().ToString('N')).exe"
    $launcherDirs = @("$temp\first launcher", "$temp\second launcher")
    foreach ($directory in $launcherDirs) {
        $null = New-Item -ItemType Directory -Path $directory
        Copy-Item -LiteralPath "$env:SystemRoot\System32\cmd.exe" -Destination (Join-Path $directory $launcherName)
    }
    $env:PATH = ($launcherDirs -join ';') + ';' + $originalPath
    if (@(Get-Command -Name $launcherName -CommandType Application).Count -ne 2) {
        throw 'Duplicate-executable regression test did not create two PATH matches.'
    }
    @{
        executable = $launcherName
        args = @('/d', '/c', 'ping -n 3 127.0.0.1 >nul & exit /b 0')
    } | ConvertTo-Json | Set-Content -LiteralPath "$temp\config.json"
    & $module { Invoke-CtrResume }
    $duplicateResult = Get-Content -LiteralPath "$temp\sessions\$($env:WT_SESSION).json" -Raw | ConvertFrom-Json
    if ($duplicateResult.state -ne 'dormant') {
        throw 'Resume failed when the launcher had multiple PATH matches.'
    }
    $env:PATH = $originalPath
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$temp\sessions\$($env:WT_SESSION).json"
    @{
        executable = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        args = @('-NoLogo', '-NoProfile', '-File', "$PSScriptRoot\support\Capture-Resume.ps1")
    } | ConvertTo-Json | Set-Content -LiteralPath "$temp\config.json"
    Write-Output 'Duplicate application names on PATH resolve to one executable and launch successfully.'
    & $module { Invoke-CtrResume }
    $received = Get-Content -LiteralPath $env:CTR_CAPTURE_ARGUMENTS -Raw | ConvertFrom-Json
    if ($received.Count -ne 2 -or $received[0] -ne '--resume' -or $received[1] -ne $record.sessionId) {
        throw 'Adapter did not pass the exact resume ID as separate arguments.'
    }
    if ((Get-Location).Path -ne $record.cwd) { throw 'Adapter did not restore the parent shell directory.' }
    $result = Get-Content -LiteralPath "$temp\sessions\$($env:WT_SESSION).json" -Raw | ConvertFrom-Json
    if ($result.state -ne 'dormant') { throw 'Returning launcher did not disarm the record.' }
    Write-Output 'Exact-ID launcher arguments, spaced cwd, parent-directory restoration, and shell-return disarming passed.'
    foreach ($failure in @(
        @{ cwd = $resumeDirectory; executable = "ctr-missing-$([guid]::NewGuid()).exe" },
        @{ cwd = "$temp\missing directory"; executable = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source }
    )) {
        $record.cwd = $failure.cwd
        $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$temp\sessions\$($env:WT_SESSION).json"
        @{ executable = $failure.executable; args = @() } | ConvertTo-Json | Set-Content -LiteralPath "$temp\config.json"
        $expectedError = $null
        try { & $module { Invoke-CtrResume } }
        catch { $expectedError = $_ }
        if (-not $expectedError) { throw 'Missing launcher/directory did not surface a launch error.' }
        $failedRecord = Get-CtrStatus
        if ($failedRecord.state -ne 'failed' -or -not $failedRecord.message) {
            throw 'Missing launcher/directory did not leave a visible failed state.'
        }
    }
    $record.cwd = $resumeDirectory
    $record.state = 'dormant'
    $record | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$temp\sessions\$($env:WT_SESSION).json"
    @{ executable = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source; args = @() } |
        ConvertTo-Json | Set-Content -LiteralPath "$temp\config.json"
    Write-Output 'Missing launcher and directory leave failed diagnostic state and a usable shell.'
    $interactive = @(@(), @('-NoLogo'), @('-wd', 'C:\x', '-NoLogo'), @('-NoExit', '-Command', 'x'),
        @('-noe', '-c', 'x'), @('-NoExit', 'script.ps1'), @('-ExecutionPolicy', 'Bypass'))
    $batch = @(@('-c', 'x'), @('-Command', 'x'), @('--command', 'x'), @('/c', 'x'), @('-f', 's.ps1'),
        @('-File', 's.ps1'), @('script.ps1'), @('-noni'), @('-NonInteractive'), @('-e', 'abc'),
        @('-ec', 'abc'), @('-enc', 'abc'), @('-NoExit', '-noni'), @('-wd', 'C:\x', '-c', 'x'))
    foreach ($case in $interactive) {
        if (-not (& $module { param($a) Test-CtrInteractiveArguments -Arguments $a } $case)) {
            throw "Interactive pwsh arguments misclassified: $case"
        }
    }
    foreach ($case in $batch) {
        if (& $module { param($a) Test-CtrInteractiveArguments -Arguments $a } $case) {
            throw "Non-interactive pwsh arguments misclassified: $case"
        }
    }
    Write-Output 'pwsh argument prefixes, -NoExit, and positional script detection passed.'
    $terminal = $env:WT_SESSION
    try {
        $env:WT_SESSION = 'not-a-guid'
        & $module { $script:Registered = $true; $script:PromptFailures = 0 }
        foreach ($attempt in 1..2) { & $module { Invoke-CtrPromptReturn } 3>$null }
        if (-not (& $module { $script:Registered })) { throw 'A transient prompt failure disabled notifications.' }
        & $module { Invoke-CtrPromptReturn } 3>$null
        if (& $module { $script:Registered }) { throw 'Persistent prompt failures kept notifications enabled.' }
    }
    finally { $env:WT_SESSION = $terminal; & $module { $script:Registered = $false; $script:PromptFailures = 0 } }
    Write-Output 'Prompt notification tolerates transient failures and stops after repeated ones.'
    if ($Theme) { oh-my-posh init pwsh --config $Theme | Invoke-Expression }
    & $module { function script:Test-CtrInteractiveShell { return $true } }
    Enable-CtrRestore
    Enable-CtrRestore
    $global:LASTEXITCODE = 73
    $render = prompt | Out-String
    if ($global:LASTEXITCODE -ne 73) { throw 'Prompt notification changed LASTEXITCODE.' }
    if ($Theme -and $render -notmatch '\x1b\]9;9;') {
        throw 'Prompt wrapper lost Oh My Posh directory reporting.'
    }
    Write-Output 'Repeated shell initialization, prompt composition, directory reporting, and exit-code preservation passed.'
}
finally {
    $env:PATH = $originalPath
    Set-Location -LiteralPath $location.Path
    Set-Item Function:\global:prompt -Value $originalPrompt
    Remove-Module CopilotTerminalRestore -ErrorAction SilentlyContinue
    foreach ($key in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key])
    }
    # The exit-code preservation check deliberately sets 73; don't leak it to the caller.
    $global:LASTEXITCODE = 0
}
