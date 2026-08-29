@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.5.0'
    GUID              = '9c19f399-e58d-4087-829a-22e5a7ec3282'
    Author            = 'Fortigi'
    CompanyName       = 'Fortigi'
    Copyright         = '(c) Fortigi. MIT licensed.'
    Description       = 'Mutation testing for PowerShell. Injects small faults (flip -eq to -ne, $true to $false, N to N+1, drop -not) into your scripts using the PowerShell AST and reports how many your Pester suite catches - the metric line coverage cannot give you. Runs mutants in a throwaway sandbox so your source is never modified. Requires Pester 5.2.0 or later AT RUN TIME, and deliberately does not declare it as a RequiredModule: PSMutant runs under whichever Pester >= 5.2.0 you have loaded rather than importing one for you. Install Pester yourself if you do not already have it.'
    PowerShellVersion = '7.0'

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
            ReleaseNotes = '**An interrupted run now writes a partial report instead of nothing.** Ctrl-C, a cancelled CI job
or a killed agent used to discard the whole run: every row lived in a list inside the loop and the
report was written only after the last mutant. On a large repo a run is long enough that losing one
is an ordinary event, not an exceptional one.

The document is marked `"mode": "Partial"` and carries `evaluated` and `planned`. It is **counts,
never a score**, for the same reason a recheck report is: the loop evaluates in candidate order, so
an interrupted run has seen whichever files sort earliest -- not a sample of anything. The schema
forbids `mutationScore` on it rather than trusting a writer never to add one.

**A schema failure on a full report now names the field that is actually missing.** The full/recheck
split was keyed on the presence of `mode`, so a full report missing any one disclosure failed the
`else` arm while the validator reported the `if` arm''s requirement:

```
Required properties ["mode"] are not present at ''''
```

`mode` is the marker whose *absence* identifies a full report, so the message named the one field
whose presence would turn the document into a different kind of report -- following it made things
worse. The discriminator is now keyed on `mutationScore`, and the same document reports:

```
Required properties ["skippedAsUncovered"] are not present at ''''
```

Measured both ways against `Test-Json`. The same documents are accepted and refused either way; only
the diagnosis changes.

**The report says how many files the score was computed over.** `filesMutated` joins
`skippedAsUncovered` and `declaredEquivalent` in the document and in the schema, for the reason
those two already exist: 100% across eight files and 100% across nine are the same number, and only
one of them covers the ninth. If your `mutate` list is narrower than your source tree -- and most
are, deliberately -- nothing in the output said so until now.

It is **optional** in the v1 schema, where the two fields beside it are required, and the difference
is not an oversight. Those two were always written and merely undeclared, so requiring them
invalidated no document that had ever existed. This field is genuinely new: requiring it would fail
every report 0.4.0 produced, and `schemaVersion` moves only when a field changes meaning or
disappears -- never when one is added. Branch on its presence.

It counts the list your config names, never a directory listing. A run cannot know about a file the
config never mentioned, so it reports what it was pointed at rather than guessing what it might have
missed; the fraction is yours to compute against your own file count.'
        }
    }
}
