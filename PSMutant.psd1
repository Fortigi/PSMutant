@{
    RootModule        = 'PSMutant.psm1'
    ModuleVersion     = '0.8.0'
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
            ReleaseNotes = '**An equivalent mutant can be declared in the code.** A `# PSMutant-Equivalent: <original> ->
<mutated>: <reason>` comment on the line directly above a mutated line declares that mutant
equivalent. It becomes the same `file:line:description` key a config entry would, so it faces the
same checks -- it must match exactly one mutant, and the run fails if the suite kills it -- and it
moves with the code instead of going stale on an edit above it. A declaration that cannot become a
key (a blank line below it, code beside it, no description or no reason) is refused before anything
is mutated. One mutant declared twice -- in the code and in the config, or under both of a config''s
key forms -- is now refused by name, where before the second key was reported as matching no
mutant.

**Logging calls are no longer mutated.** Mutants inside the arguments of `Write-Verbose`,
`Write-Debug`, `Write-Information`, `Write-Host` and `Write-Progress` are skipped, because the text
of a log line rarely tells you anything about your tests. The new `ignoreCalls` config key replaces
that list, and `[]` turns it off. Every operator''s mutants inside such a call are skipped, and the
number is printed beside the score and written to the report as `skippedAsIgnoredCall`, with the
list applied as `ignoreCalls`; neither is counted in `total` or either score. Mutant ids do not
change, so a recheck still matches. **This can lower your mutant count after upgrading** -- a run
that mutated inside logging calls before will now skip those mutants; set `"ignoreCalls": []` to
keep the old behaviour. `Write-Warning`, `Write-Error` and `throw` are not in the default, because
tests often assert those messages. A `-ListOnly` result carries the count as `Ignored`.

**Patterns in `mutate` and `tests`, and pairing by name.** An entry holding `*` or `?` is a pattern,
read as PSComplexity reads its config''s `exclude`: `*` and `?` stay within one path segment, `**`
spans any number of them, and a pattern also matches everything below what it names. Patterns are
expanded once at start-up, before anything else reads the lists, and the files each matched are
printed, so the run still names exactly what it covers. A pattern matching no file is refused,
naming every such pattern at once. The new `testsByConvention` switch pairs a mutate file that has no
`tests` entry with `tests/<Name>.Tests.ps1` when that exists; an explicit entry always wins, each
pair is printed, and `tests` may then be `{}`. Off by default, so upgrading changes no mapping.
Matched without regard to case on every platform, as every other path here is.'
        }
    }
}
