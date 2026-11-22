$script:Binary = Join-Path (Split-Path $PSScriptRoot -Parent) 'copilot-terminal-restore.exe'
if (-not (Test-Path -LiteralPath $script:Binary)) {
    $script:Binary = Join-Path (Split-Path $PSScriptRoot -Parent) 'target\release\copilot-terminal-restore.exe'
}
$script:Registered = $false
$script:PromptFailures = 0

function Test-CtrPromptWrapper {
    param([scriptblock]$Prompt, [string]$Marker)
    for ($i = 0; $i -lt 32 -and $Prompt; $i++) {
        $text = $Prompt.ToString()
        if ($text.Contains($Marker)) { return $true }
        if (-not $Prompt.Module -or
            ($text -notmatch 'CTR_DIRECTORY_REPORT|Invoke-CtrPromptReturn')) { return $false }
        $Prompt = $Prompt.Module.SessionState.PSVariable.GetValue('original')
    }
    return $false
}

function Enable-CtrDirectoryReporting {
    [CmdletBinding()]
    param()
    if (-not $env:WT_SESSION -or [Console]::IsOutputRedirected) { return }
    $original = (Get-Command prompt -CommandType Function -ErrorAction Stop).ScriptBlock
    if (Test-CtrPromptWrapper -Prompt $original -Marker 'CTR_DIRECTORY_REPORT') { return }
    $wrapped = {
        # CTR_DIRECTORY_REPORT: keep the user's prompt and report only filesystem locations.
        $rendered = & $original
        $location = Get-Location
        if ($location.Provider.Name -eq 'FileSystem') {
            $path = $location.ProviderPath
            if ($path -match '[\x00-\x1f\x7f]') {
                Write-Warning 'Directory reporting skipped: path contains a terminal control character.'
            } else {
                [Console]::Write("$([char]27)]9;9;$path$([char]27)\")
            }
        }
        $rendered
    }.GetNewClosure()
    Set-Item Function:\global:prompt -Value $wrapped
}

function Invoke-CtrCore {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$Json)
    if (-not (Test-Path -LiteralPath $script:Binary)) {
        throw "Copilot restore executable not found: $script:Binary"
    }
    $oldExitCode = $global:LASTEXITCODE
    try {
        $output = & $script:Binary @Arguments
        if ($LASTEXITCODE -ne 0) { throw "Copilot restore operation '$($Arguments[0])' failed; see diagnostic above." }
        if ($Json) { $output | ConvertFrom-Json -ErrorAction Stop }
        elseif ($output) { $output }
    }
    finally { $global:LASTEXITCODE = $oldExitCode }
}

function Test-CtrInteractiveArguments {
    param([string[]]$Arguments)
    # pwsh accepts unambiguous parameter prefixes; -NoExit keeps a command or file shell interactive.
    $valueParameters = @('workingdirectory', 'executionpolicy', 'settingsfile', 'configurationname',
        'configurationfile', 'custompipename', 'inputformat', 'outputformat', 'windowstyle')
    $noExit = $false
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        if ($Arguments[$i] -notmatch '^(?:--?|/)([A-Za-z]+)(?::.*)?$') { return $noExit }
        $name = $Matches[1].ToLowerInvariant()
        if ($name -in @('wd', 'ep', 'ex', 'if', 'of', 'o', 'w') -or
            ($name.Length -ge 3 -and @($valueParameters | Where-Object { $_.StartsWith($name) }).Count)) {
            $i++
            continue
        }
        if ($name.Length -ge 4 -and 'noninteractive'.StartsWith($name)) { return $false }
        if ($name.Length -ge 3 -and 'noexit'.StartsWith($name)) { $noExit = $true; continue }
        if ($name -in @('c', 'f', 'e', 'ec', 'cwa') -or
            ($name.Length -ge 3 -and ('command'.StartsWith($name) -or 'commandwithargs'.StartsWith($name) -or
                'encodedcommand'.StartsWith($name))) -or
            ($name.Length -ge 2 -and 'file'.StartsWith($name))) {
            return $noExit
        }
    }
    return $true
}

function Test-CtrInteractiveShell {
    if ($Host.Name -ne 'ConsoleHost' -or [Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        return $false
    }
    if (-not (Test-CtrInteractiveArguments -Arguments @([Environment]::GetCommandLineArgs() | Select-Object -Skip 1))) {
        return $false
    }
    $current = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
    for ($i = 0; $i -lt 16 -and $current.ParentProcessId; $i++) {
        $current = Get-CimInstance Win32_Process -Filter "ProcessId=$($current.ParentProcessId)" -ErrorAction Stop
        if (-not $current) { return $false }
        if ($current.Name -eq 'WindowsTerminal.exe') { return $true }
        if ($current.Name -in @('copilot.exe', 'pwsh.exe', 'powershell.exe')) { return $false }
    }
    return $false
}

function Invoke-CtrResume {
    $decision = Invoke-CtrCore -Arguments @('init') -Json
    if ($decision.action -ne 'restore') {
        if ($decision.state -in @('failed', 'ambiguous')) {
            Write-Warning "Copilot restore: $($decision.message)"
        }
        return
    }
    $oldHome = $env:COPILOT_HOME
    $oldExitCode = $global:LASTEXITCODE
    try {
        Set-Location -LiteralPath $decision.cwd -ErrorAction Stop
        $env:COPILOT_HOME = $decision.copilotHome
        $launcher = Get-Command -Name $decision.executable -CommandType Application -ErrorAction Stop |
            Select-Object -First 1
        $arguments = @($decision.args) + @('--resume', $decision.sessionId)
        $start = [Diagnostics.ProcessStartInfo]::new($launcher.Source)
        $start.UseShellExecute = $false
        foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
        $child = [Diagnostics.Process]::Start($start)
        try {
            try { Invoke-CtrCore -Arguments @('launched', $decision.generation, "$($child.Id)") }
            catch { Write-Warning "Resume process is running but ownership registration failed: $($_.Exception.Message)" }
            $child.WaitForExit()
            if ($child.ExitCode -ne 0) { Write-Warning "Copilot resume launcher exited with code $($child.ExitCode)." }
        }
        finally { $child.Dispose() }
        Invoke-CtrCore -Arguments @('prompt')
    }
    catch {
        $failure = $_
        Invoke-CtrCore -Arguments @('fail', $failure.Exception.Message)
        throw $failure
    }
    finally {
        $env:COPILOT_HOME = $oldHome
        $global:LASTEXITCODE = $oldExitCode
    }
}

function Enable-CtrRestore {
    [CmdletBinding()]
    param()
    if ($env:CTR_DISABLE -eq '1' -or -not $env:WT_SESSION) { return }
    if (-not (Test-CtrInteractiveShell)) { return }
    try {
        $owner = Invoke-CtrCore -Arguments @('shell-owner', "$PID") -Json
        $env:CTR_SHELL_OWNER = $owner | ConvertTo-Json -Compress
        $script:Registered = $true
        $original = (Get-Command prompt -CommandType Function -ErrorAction Stop).ScriptBlock
        if (-not (Test-CtrPromptWrapper -Prompt $original -Marker 'Invoke-CtrPromptReturn')) {
            $wrapped = {
                $rendered = & $original
                Invoke-CtrPromptReturn
                $rendered
            }.GetNewClosure()
            Set-Item -Path Function:\global:prompt -Value $wrapped
        }
        Invoke-CtrResume
    }
    catch { Write-Warning "Copilot restore startup failed: $($_.Exception.Message)" }
}

function Invoke-CtrPromptReturn {
    if (-not $script:Registered -or $env:CTR_DISABLE -eq '1') { return }
    try {
        Invoke-CtrCore -Arguments @('prompt')
        $script:PromptFailures = 0
    }
    catch {
        # Tolerate transient failures; persistent ones stop notifications rather than warn every prompt.
        $script:PromptFailures++
        if ($script:PromptFailures -ge 3) {
            $script:Registered = $false
            Write-Warning "Copilot restore prompt notification failed repeatedly; notifications disabled in this shell: $($_.Exception.Message)"
        }
        else { Write-Warning "Copilot restore prompt notification failed: $($_.Exception.Message)" }
    }
}

function Get-CtrStatus {
    Invoke-CtrCore -Arguments @('status') -Json
}

function Resume-CtrSession {
    if (-not $script:Registered) { throw 'This is not a registered interactive Windows Terminal shell.' }
    Invoke-CtrCore -Arguments @('retry')
    Invoke-CtrResume
}

function Disable-CtrSession {
    Invoke-CtrCore -Arguments @('forget')
}
