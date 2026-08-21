@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.3.1'
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
            ReleaseNotes = 'BREAKING: the module exports ONE function. Get-PSMutationCandidate and Set-PSMutationText are no longer public - between them they trafficked an undeclared object that nothing versioned or tested as a contract, discoverable only by running them. The public surface is Invoke-PSMutation and the report JSON, and both are now written down: schemas/ ships a JSON Schema for the report format and one for the config format, so a config can be checked before a run and a report validated without reading this project''s tests. Reports also record how they were produced - schema version, producing module version, timestamp, and the baseline, total and per-mutant-timeout durations - so two runs are comparable and a suite drifting toward its timeout bound is visible before it crosses. FIXED, and all of the same kind - a run that reports a number it did not measure: a config value of the wrong type was accepted and silently emptied the per-mutant timeout, and a timeout expiry counts as a kill; an unrecognised config key was ignored, so thresholds.brake left the break gate unable to fail and a misspelled operator was dropped and then reported as though it had run; every score printed green, 0% included, for any config without colour bands; and an equivalence declaration could silently exclude every mutant sharing its line. Unknown keys and wrong types are now errors that name the key and suggest the nearest valid one, equivalence declarations are keyed by enclosing function so they stop going stale when unrelated lines move, and one that matches more than one mutant is refused as ambiguous rather than banked. -RecheckFrom now skips mutants the config already declared unkillable and can seed another recheck, so the loop narrows as you write assertions. Get-Help Invoke-PSMutation now returns the real documentation - a file header was shadowing it - with a written description for every parameter and five worked examples. Requires PowerShell 7.2+ and Pester 5.0+; Pester is a run-time dependency and is deliberately not declared in RequiredModules, so PSMutant runs under whichever Pester 5 or 6 your repo already has.'
        }
    }
}
