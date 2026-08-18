@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.2.2'
    GUID              = '9c19f399-e58d-4087-829a-22e5a7ec3282'
    Author            = 'Fortigi'
    CompanyName       = 'Fortigi'
    Copyright         = '(c) Fortigi. MIT licensed.'
    Description       = 'Mutation testing for PowerShell. Injects small faults (flip -eq to -ne, $true to $false, N to N+1, drop -not) into your scripts using the PowerShell AST and reports how many your Pester suite catches - the metric line coverage cannot give you. Runs mutants in a throwaway sandbox so your source is never modified.'
    PowerShellVersion = '7.2'

    FunctionsToExport = @('Invoke-PSMutation', 'Get-PSMutationCandidate', 'Set-PSMutationText')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    RequiredModules   = @(@{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' })

    PrivateData = @{
        PSData = @{
            Tags         = @('mutation-testing', 'testing', 'pester', 'ast', 'quality', 'test-quality', 'coverage')
            LicenseUri   = 'https://github.com/Fortigi/PSMutant/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Fortigi/PSMutant'
            ReleaseNotes = 'Fixes a silent, entirely fake 100% score on any machine with two Pester versions installed. Mutants run in a child runspace, and that runspace resolved Pester by name - getting the newest version installed rather than the one already loaded. Assemblies are per-process, so the child died on an incompatible Pester.dll, produced no verdict, and a mutant with no verdict was counted as Killed: every mutant died and the run reported a perfect score over tests that never ran. The child is now pinned to the loaded module''s path, and a run that cannot evaluate a mutant fails instead of scoring it. Also fixes an abort when a suitable Pester was already loaded. Coverage and self-mutation both at 100%.'
        }
    }
}
