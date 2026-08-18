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
            ReleaseNotes = 'Adds -RecheckFrom (re-run only a previous report''s survivors, with counts instead of a score and a refusal when the source or operator set moved) and the equivalents config map (declare mutants that cannot change behaviour, with reasons; the run fails if a declaration is killed or goes stale). Fixes a throw on an empty candidate set. Coverage and self-mutation both at 100%.'
        }
    }
}
