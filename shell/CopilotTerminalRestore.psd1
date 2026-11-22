@{
    RootModule = 'CopilotTerminalRestore.psm1'
    ModuleVersion = '0.1.0'
    GUID = 'e991b7d4-44cb-4ea4-b35e-b0b8d655c245'
    PowerShellVersion = '7.4'
    FunctionsToExport = @(
        'Enable-CtrRestore', 'Get-CtrStatus', 'Resume-CtrSession',
        'Disable-CtrSession', 'Invoke-CtrPromptReturn', 'Enable-CtrDirectoryReporting'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
}
