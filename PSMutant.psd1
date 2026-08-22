@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.3.2'
    GUID              = '9c19f399-e58d-4087-829a-22e5a7ec3282'
    Author            = 'Fortigi'
    CompanyName       = 'Fortigi'
    Copyright         = '(c) Fortigi. MIT licensed.'
    Description       = 'Mutation testing for PowerShell. Injects small faults (flip -eq to -ne, $true to $false, N to N+1, drop -not) into your scripts using the PowerShell AST and reports how many your Pester suite catches - the metric line coverage cannot give you. Runs mutants in a throwaway sandbox so your source is never modified. Requires Pester 5.0.0 or later AT RUN TIME, and deliberately does not declare it as a RequiredModule: PSMutant runs under whichever Pester >= 5 you have loaded rather than importing one for you. Install Pester yourself if you do not already have it.'
    PowerShellVersion = '7.2'

    # One function. Get-PSMutationCandidate and Set-PSMutationText used to be exported too,
    # and between them they trafficked a nine-field [pscustomobject] that nothing declared,
    # tested as a contract or versioned -- discoverable only by running the function and
    # inspecting the output, and unchangeable once someone had. Neither was ever mentioned in
    # the README, and Set-PSMutationText had exactly one caller, inside this module (#48).
    #
    # "What would you mutate?" is a fair question to ask, and the answer should be a rendering
    # this module controls -- see #10's -ListOnly -- not a raw AST walker handing out its
    # internals.
    FunctionsToExport = @('Invoke-PSMutation')
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
            ReleaseNotes = '**A per-mutant timeout that resolves too low is now refused instead of faking a perfect
score.** The budget is `max(timeoutFloorSeconds, baseline x timeoutFactor)`, and with a small
enough floor *and* factor it could resolve to zero. A zero-second budget expires immediately,
an expired mutant counts as a kill, and so every mutant was killed on the clock rather than on
behaviour -- 100%, exit 0, over tests that never ran. The budget must now be at least as long
as your unmutated suite took, and a config that asks for less fails with a message saying so.

If this affects you, your reported score was wrong in the flattering direction, and the run
that fails after upgrading is the honest one.

**A config path that escapes the source root is now refused.** Every path in a config is
copied into a temp sandbox and mutated there; a leading `..` survived that mapping, so a path
like `../shared/Util.ps1` was mutated **where it lives**, in your working tree. Interrupt such
a run and the mutated file stays on disk. Paths that merely contain `..` and still resolve
inside -- `src/../src/a.ps1` -- keep working.'
        }
    }
}
