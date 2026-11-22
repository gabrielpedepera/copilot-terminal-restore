param([Parameter(Mandatory)][string]$Root)
$ErrorActionPreference = 'Stop'
$env:WT_SESSION = [guid]::NewGuid().ToString()
$module = Import-Module "$Root\shell\CopilotTerminalRestore.psd1" -PassThru
& $module {
    function script:Test-CtrInteractiveShell { return $true }
    $script:PromptObservations = 0
    function script:Invoke-CtrCore {
        param([string[]]$Arguments, [switch]$Json)
        switch ($Arguments[0]) {
            'shell-owner' { [pscustomobject]@{ pid = $PID; created = 1 } }
            'init' { [pscustomobject]@{ action = 'none'; state = 'dormant' } }
            'prompt' { $script:PromptObservations++ }
            default { throw "Unexpected operation $($Arguments[0])" }
        }
    }
}
function global:prompt { 'ORIGINAL_PROMPT> ' }
Enable-CtrRestore
Enable-CtrDirectoryReporting
Enable-CtrRestore
Enable-CtrDirectoryReporting
$global:LASTEXITCODE = 73
$rendered = prompt | Out-String
if ($rendered.Trim() -ne 'ORIGINAL_PROMPT>') { throw "Directory reporting replaced the original prompt: $rendered" }
if ($LASTEXITCODE -ne 73) { throw 'Directory reporting changed the last exit code.' }
if ((& $module { $script:PromptObservations }) -ne 1) { throw 'Repeated initialization duplicated prompt-return notifications.' }
[Console]::WriteLine('DIRECTORY_REPORT_TEST_PASSED')
