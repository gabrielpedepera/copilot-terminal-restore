$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not ('CopilotTerminalRestore.Tests.PseudoTerminal' -as [type])) {
    Add-Type -Path "$PSScriptRoot\support\PseudoTerminal.cs"
}
$pwsh = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
$command = "`"$pwsh`" -NoLogo -NoProfile -File `"$PSScriptRoot\support\Invoke-DirectoryConsole.ps1`" -Root `"$root`""
$terminal = [CopilotTerminalRestore.Tests.PseudoTerminal]::new($command, $root)
try {
    $deadline = [datetime]::UtcNow.AddSeconds(20)
    while (-not $terminal.HasExited -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 100 }
    Start-Sleep -Milliseconds 300
    $output = $terminal.Output
    if ($output -notmatch 'DIRECTORY_REPORT_TEST_PASSED') { throw "Prompt test failed: $output" }
    if ([regex]::Matches($output, '\x1b\]9;9;').Count -ne 1) {
        throw 'Expected exactly one directory signal after repeated initialization.'
    }
    Write-Output 'Plain PowerShell directory reporting emits OSC 9;9, preserves prompt/exit code, and is idempotent.'
}
finally {
    $terminal.CloseConsole()
    if (-not $terminal.HasExited) { Stop-Process -Id $terminal.ProcessId -Force }
    $terminal.Dispose()
}
