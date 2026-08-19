@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.3.0'
    GUID              = '9c19f399-e58d-4087-829a-22e5a7ec3282'
    Author            = 'Fortigi'
    CompanyName       = 'Fortigi'
    Copyright         = '(c) Fortigi. MIT licensed.'
    Description       = 'Mutation testing for PowerShell. Injects small faults (flip -eq to -ne, $true to $false, N to N+1, drop -not) into your scripts using the PowerShell AST and reports how many your Pester suite catches - the metric line coverage cannot give you. Runs mutants in a throwaway sandbox so your source is never modified. Requires Pester 5.0.0 or later AT RUN TIME, and deliberately does not declare it as a RequiredModule: PSMutant runs under whichever Pester >= 5 you have loaded rather than importing one for you. Install Pester yourself if you do not already have it.'
    PowerShellVersion = '7.2'

    FunctionsToExport = @('Invoke-PSMutation', 'Get-PSMutationCandidate', 'Set-PSMutationText')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()

    # NO RequiredModules entry for Pester, deliberately. ModuleVersion there is a MINIMUM
    # and PowerShell satisfies it by importing the NEWEST installed version -- at import
    # time, before Assert-PSMutationPester or Get-PSMutationPesterPath can have a say. That
    # made `Import-Module PSMutant` followed by `Import-Module Pester -RequiredVersion 5.7.1`
    # fail on an assembly collision and leave the caller on 6.1.0, while the same two lines
    # in the other order worked -- issue #16's failure one layer up, with no diagnostic.
    #
    # Pester is needed at RUN time, not import time, and Assert-PSMutationPester is the single
    # point that enforces it: it accepts an already-loaded Pester >= 5, imports one only when
    # none is loaded, and refuses with an actionable message otherwise. The cost is that
    # Install-Module PSMutant no longer pulls Pester in for you; that is stated in the
    # description, the README and the error message.

    PrivateData = @{
        PSData = @{
            Tags         = @('mutation-testing', 'testing', 'pester', 'ast', 'quality', 'test-quality', 'coverage')
            LicenseUri   = 'https://github.com/Fortigi/PSMutant/blob/main/LICENSE'
            ProjectUri   = 'https://github.com/Fortigi/PSMutant'
            ReleaseNotes = 'Adds three OPT-IN mutation operators that reach decisions no expression operator can touch. Code whose logic lives in structure rather than in an expression - a phase guard like if ($SyncUsers) { ... }, or a chain of if ($Ref.Value) { return ... } fallbacks - contains no comparison, literal or negation, so the default set produced ZERO mutants for it and the file scored a vacuous 100%. ConditionForcing forces an if/elseif condition to $true and to $false; ConditionalBoundary shifts a boundary (-gt <-> -ge, -lt <-> -le), the off-by-one that the existing -gt -> -le swap cannot produce; ReturnValue replaces a returned value with $null. All three are opt-in: enabling one roughly doubles the mutant count and lowers the score, so a repo gating on thresholds.break would go red purely from upgrading, and mutants are renumbered so existing reports can no longer seed a -RecheckFrom run. PSMutant runs all three against itself: 100% over 303 mutants, coverage 100%.'
        }
    }
}
