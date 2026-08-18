@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.3.0'
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
            ReleaseNotes = 'Adds three OPT-IN mutation operators that reach decisions no expression operator can touch. Code whose logic lives in structure rather than in an expression - a phase guard like if ($SyncUsers) { ... }, or a chain of if ($Ref.Value) { return ... } fallbacks - contains no comparison, literal or negation, so the default set produced ZERO mutants for it and the file scored a vacuous 100%. ConditionForcing forces an if/elseif condition to $true and to $false; ConditionalBoundary shifts a boundary (-gt <-> -ge, -lt <-> -le), the off-by-one that the existing -gt -> -le swap cannot produce; ReturnValue replaces a returned value with $null. All three are opt-in: enabling one roughly doubles the mutant count and lowers the score, so a repo gating on thresholds.break would go red purely from upgrading, and mutants are renumbered so existing reports can no longer seed a -RecheckFrom run. PSMutant runs all three against itself: 100% over 303 mutants, coverage 100%.'
        }
    }
}
